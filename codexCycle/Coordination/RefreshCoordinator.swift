import AppKit
import Foundation
import OSLog

enum RefreshTrigger {
    case startup
    case timer
    case wake
    case manual
    case serverEvent
    case resetBoundary
    case processRecovery
    case dailyCodexRequest
    case manualCodexRequest
}

struct DailyCodexRequestSchedule {
    let calendar: Calendar
    let hour: Int

    init(calendar: Calendar = .autoupdatingCurrent, hour: Int = 7) {
        self.calendar = calendar
        self.hour = hour
    }

    func isDue(now: Date, lastAttemptAt: Date?) -> Bool {
        guard let today = calendar.date(
            bySettingHour: hour,
            minute: 0,
            second: 0,
            of: now
        ), now >= today else {
            return false
        }
        guard let lastAttemptAt else { return true }
        return !calendar.isDate(lastAttemptAt, inSameDayAs: now)
    }

    func nextFireDate(after now: Date) -> Date? {
        guard let today = calendar.date(
            bySettingHour: hour,
            minute: 0,
            second: 0,
            of: now
        ) else {
            return nil
        }
        if now < today {
            return today
        }
        return calendar.date(byAdding: .day, value: 1, to: today)
    }
}

final class RefreshCoordinator {
    private let service: CodexUsageService
    private let cache: QuotaUsageCaching
    private let menuController: StatusMenuController
    private let loginItemManager: LoginItemManager
    private let preferences: AppPreferences
    private let dailySchedule: DailyCodexRequestSchedule
    private let logger = Logger(subsystem: "com.fxl.codexCycle", category: "refresh")

    private var state: QuotaDisplayState = .unavailable(nil)
    private var refreshing = false
    private var quotaRefreshRequestInFlight = false
    private var requestFeedback: RequestFeedbackState = .idle
    private var pollTimer: Timer?
    private var relativeTimer: Timer?
    private var expirationBoundaryTimer: Timer?
    private var reconnectTimer: Timer?
    private var dailyRequestTimer: Timer?
    private var requestFeedbackTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var reconnectAttempt = 0
    private let reconnectDelays: [TimeInterval] = [1, 5, 30, 300]

    init(
        service: CodexUsageService,
        cache: QuotaUsageCaching,
        menuController: StatusMenuController,
        loginItemManager: LoginItemManager,
        preferences: AppPreferences,
        dailySchedule: DailyCodexRequestSchedule = DailyCodexRequestSchedule()
    ) {
        self.service = service
        self.cache = cache
        self.menuController = menuController
        self.loginItemManager = loginItemManager
        self.preferences = preferences
        self.dailySchedule = dailySchedule
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))

        loginItemManager.registerOnFirstLaunchIfNeeded()

        if let cached = cache.load(now: Date()) {
            state = .stale(cached, nil)
            scheduleExpirationBoundaryTimer()
        }

        service.onRateLimitsUpdated = { [weak self] in
            self?.requestRefresh(trigger: .serverEvent)
        }
        service.onUnexpectedTermination = { [weak self] error in
            self?.handleUnexpectedProcessTermination(error)
        }

        menuController.onRefresh = { [weak self] in
            self?.requestRefresh(trigger: .manual)
        }
        menuController.onRequest = { [weak self] in
            self?.startManualCodexRequest()
        }
        menuController.onSelectLanguage = { [weak self] language in
            guard let self else { return }
            self.preferences.appLanguage = language
            self.menuController.setLanguage(language)
        }
        menuController.onOpenLoginSettings = { [weak self] in
            self?.loginItemManager.openSystemSettings()
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.invalidateExpiredReadingsAndRefreshIfNeeded()
            self?.requestRefresh(trigger: .wake)
            self?.checkDailyCodexRequest()
        }

        schedulePollTimer()
        scheduleRelativeTimer()
        scheduleDailyRequestTimer()
        updatePresentation()
        requestRefresh(trigger: .startup)
        checkDailyCodexRequest()
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        pollTimer?.invalidate()
        relativeTimer?.invalidate()
        expirationBoundaryTimer?.invalidate()
        reconnectTimer?.invalidate()
        dailyRequestTimer?.invalidate()
        requestFeedbackTimer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        service.stop()
    }

    func requestRefresh(trigger: RefreshTrigger) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !refreshing else { return }

        refreshing = true
        updatePresentation()

        service.fetch { [weak self] result in
            guard let self else { return }
            self.refreshing = false

            switch result {
            case .success(let snapshot):
                self.state = .fresh(snapshot)
                self.cache.save(snapshot)
                self.reconnectAttempt = 0
                self.reconnectTimer?.invalidate()
                self.reconnectTimer = nil
                self.schedulePollTimer()
            case .failure(let error):
                let reason = DisplayErrorReason.classify(error)
                if error is QuotaUsageError {
                    self.cache.clear()
                    self.state = .unavailable(reason)
                } else {
                    self.retainValidSnapshotOrBecomeUnavailable(reason)
                }

                if case .processRecovery = trigger {
                    self.scheduleReconnectAttempt()
                }
            }

            self.scheduleExpirationBoundaryTimer()
            self.updatePresentation()
            self.checkDailyCodexRequest()
        }
    }

    private func schedulePollTimer() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            self?.invalidateExpiredReadingsAndRefreshIfNeeded()
            self?.requestRefresh(trigger: .timer)
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func scheduleRelativeTimer() {
        relativeTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.invalidateExpiredReadingsAndRefreshIfNeeded()
            self.updatePresentation()
        }
        RunLoop.main.add(timer, forMode: .common)
        relativeTimer = timer
    }

    private func scheduleDailyRequestTimer(now: Date = Date()) {
        dailyRequestTimer?.invalidate()
        dailyRequestTimer = nil
        guard let fireDate = dailySchedule.nextFireDate(after: now) else { return }

        let timer = Timer(fireAt: fireDate, interval: 0, target: self,
                          selector: #selector(dailyRequestTimerFired),
                          userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        dailyRequestTimer = timer
    }

    @objc private func dailyRequestTimerFired() {
        dailyRequestTimer = nil
        checkDailyCodexRequest()
    }

    private func checkDailyCodexRequest(now: Date = Date()) {
        scheduleDailyRequestTimer(now: now)
        guard dailySchedule.isDue(
            now: now,
            lastAttemptAt: preferences.lastDailyCodexRequestAt
        ) else { return }
        guard !refreshing, !quotaRefreshRequestInFlight else { return }

        beginRequestFeedback()
        quotaRefreshRequestInFlight = true
        updatePresentation()
        let started = service.startQuotaRefreshRequest { [weak self] result in
            guard let self else { return }
            self.quotaRefreshRequestInFlight = false
            self.completeRequestFeedback(result)
            if case .failure = result {
                self.logger.error("Daily Codex quota-refresh request failed")
            }
            self.requestRefresh(trigger: .dailyCodexRequest)
        }

        if started {
            preferences.lastDailyCodexRequestAt = now
            logger.info("Started daily Codex quota-refresh request")
        } else {
            quotaRefreshRequestInFlight = false
            completeRequestFeedback(.failure(
                CodexQuotaRefreshRequestError.runtimeUnavailable
            ))
        }
    }

    private func startManualCodexRequest(now: Date = Date()) {
        guard !refreshing, !quotaRefreshRequestInFlight else { return }

        beginRequestFeedback()
        quotaRefreshRequestInFlight = true
        updatePresentation()
        let started = service.startQuotaRefreshRequest { [weak self] result in
            guard let self else { return }
            self.quotaRefreshRequestInFlight = false
            self.completeRequestFeedback(result)
            if case .failure = result {
                self.logger.error("Manual Codex quota-refresh request failed")
            }
            self.requestRefresh(trigger: .manualCodexRequest)
        }

        guard started else {
            quotaRefreshRequestInFlight = false
            completeRequestFeedback(.failure(
                CodexQuotaRefreshRequestError.runtimeUnavailable
            ))
            return
        }

        if dailySchedule.isDue(
            now: now,
            lastAttemptAt: preferences.lastDailyCodexRequestAt
        ) {
            preferences.lastDailyCodexRequestAt = now
        }
        logger.info("Started manual Codex quota-refresh request")
    }

    private func beginRequestFeedback() {
        requestFeedbackTimer?.invalidate()
        requestFeedbackTimer = nil
        requestFeedback = .requesting
    }

    private func completeRequestFeedback(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            requestFeedback = .succeeded
        case .failure:
            requestFeedback = .failed
        }
        updatePresentation()

        requestFeedbackTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.requestFeedbackTimer = nil
            self.requestFeedback = .idle
            self.updatePresentation()
        }
        RunLoop.main.add(timer, forMode: .common)
        requestFeedbackTimer = timer
    }

    private func scheduleExpirationBoundaryTimer() {
        expirationBoundaryTimer?.invalidate()
        expirationBoundaryTimer = nil

        guard let resetsAt = state.snapshot?.earliestResetAt else {
            return
        }

        let delay = max(0.05, resetsAt.timeIntervalSinceNow + 0.05)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.expirationBoundaryTimer = nil
            self.invalidateExpiredReadingsAndRefreshIfNeeded()
            if self.expirationBoundaryTimer == nil {
                self.scheduleExpirationBoundaryTimer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        expirationBoundaryTimer = timer
    }

    private func invalidateExpiredReadingsAndRefreshIfNeeded() {
        let now = Date()
        guard let snapshot = state.snapshot else { return }
        let validSnapshot = snapshot.removingExpiredReadings(at: now)
        guard validSnapshot != snapshot else { return }

        cache.clear()
        if let validSnapshot {
            cache.save(validSnapshot)
            switch state {
            case .fresh:
                state = .fresh(validSnapshot)
            case .stale(_, let reason):
                state = .stale(validSnapshot, reason)
            case .unavailable:
                state = .stale(validSnapshot, nil)
            }
        } else {
            state = .unavailable(nil)
        }

        scheduleExpirationBoundaryTimer()
        updatePresentation()
        requestRefresh(trigger: .resetBoundary)
    }

    private func handleUnexpectedProcessTermination(_ error: Error) {
        let reason = DisplayErrorReason.classify(error)
        retainValidSnapshotOrBecomeUnavailable(reason)
        scheduleExpirationBoundaryTimer()
        updatePresentation()
        scheduleReconnectAttempt()
    }

    private func retainValidSnapshotOrBecomeUnavailable(_ reason: DisplayErrorReason) {
        if let snapshot = state.snapshot?.removingExpiredReadings(at: Date()) {
            state = .stale(snapshot, reason)
            cache.save(snapshot)
        } else {
            cache.clear()
            state = .unavailable(reason)
        }
    }

    private func scheduleReconnectAttempt() {
        guard reconnectTimer == nil else { return }

        let index = min(reconnectAttempt, reconnectDelays.count - 1)
        let delay = reconnectDelays[index]
        reconnectAttempt = min(reconnectAttempt + 1, reconnectDelays.count - 1)

        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.reconnectTimer = nil
            self.service.resetConnection()
            self.requestRefresh(trigger: .processRecovery)
        }
        RunLoop.main.add(timer, forMode: .common)
        reconnectTimer = timer
        logger.info("Scheduled Codex app-server recovery")
    }

    private func updatePresentation() {
        menuController.update(
            state: state,
            refreshing: refreshing,
            requestFeedback: requestFeedback,
            canRequest: service.canStartQuotaRefreshRequest,
            loginLaunchState: loginItemManager.state
        )
    }
}
