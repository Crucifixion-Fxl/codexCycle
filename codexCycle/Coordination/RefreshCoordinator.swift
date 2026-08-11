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
}

final class RefreshCoordinator {
    private let service: CodexUsageService
    private let cache: WeeklyQuotaCaching
    private let menuController: StatusMenuController
    private let loginItemManager: LoginItemManager
    private let preferences: AppPreferences
    private let logger = Logger(subsystem: "com.fxl.codexCycle", category: "refresh")

    private var state: WeeklyQuotaDisplayState = .unavailable(nil)
    private var refreshing = false
    private var pollTimer: Timer?
    private var relativeTimer: Timer?
    private var expirationBoundaryTimer: Timer?
    private var reconnectTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var reconnectAttempt = 0
    private let reconnectDelays: [TimeInterval] = [1, 5, 30, 300]

    init(
        service: CodexUsageService,
        cache: WeeklyQuotaCaching,
        menuController: StatusMenuController,
        loginItemManager: LoginItemManager,
        preferences: AppPreferences
    ) {
        self.service = service
        self.cache = cache
        self.menuController = menuController
        self.loginItemManager = loginItemManager
        self.preferences = preferences
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
        menuController.onSelectLanguage = { [weak self] language in
            self?.selectLanguage(language)
        }
        menuController.onOpenLoginSettings = { [weak self] in
            self?.loginItemManager.openSystemSettings()
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.invalidateExpiredReadingAndRefreshIfNeeded()
            self?.requestRefresh(trigger: .wake)
        }

        schedulePollTimer()
        scheduleRelativeTimer()
        updatePresentation()
        requestRefresh(trigger: .startup)
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        pollTimer?.invalidate()
        relativeTimer?.invalidate()
        expirationBoundaryTimer?.invalidate()
        reconnectTimer?.invalidate()
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
            case .success(let reading):
                self.state = .fresh(reading)
                self.cache.save(reading)
                self.reconnectAttempt = 0
                self.reconnectTimer?.invalidate()
                self.reconnectTimer = nil
                self.schedulePollTimer()
            case .failure(let error):
                let reason = DisplayErrorReason.classify(error)
                if error is WeeklyQuotaError {
                    self.cache.clear()
                    self.state = .unavailable(reason)
                } else if let reading = self.state.reading,
                          reading.isValid(at: Date()) {
                    self.state = .stale(reading, reason)
                    self.cache.save(reading)
                } else {
                    self.cache.clear()
                    self.state = .unavailable(reason)
                }

                if case .processRecovery = trigger {
                    self.scheduleReconnectAttempt()
                }
            }

            self.scheduleExpirationBoundaryTimer()
            self.updatePresentation()
        }
    }

    private func schedulePollTimer() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            self?.invalidateExpiredReadingAndRefreshIfNeeded()
            self?.requestRefresh(trigger: .timer)
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func scheduleRelativeTimer() {
        relativeTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.invalidateExpiredReadingAndRefreshIfNeeded()
            self.updatePresentation()
        }
        RunLoop.main.add(timer, forMode: .common)
        relativeTimer = timer
    }

    private func scheduleExpirationBoundaryTimer() {
        expirationBoundaryTimer?.invalidate()
        expirationBoundaryTimer = nil

        guard let resetsAt = state.reading?.resetsAt else {
            return
        }

        let delay = max(0.05, resetsAt.timeIntervalSinceNow + 0.05)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.expirationBoundaryTimer = nil
            self.invalidateExpiredReadingAndRefreshIfNeeded()
            if self.expirationBoundaryTimer == nil {
                self.scheduleExpirationBoundaryTimer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        expirationBoundaryTimer = timer
    }

    private func invalidateExpiredReadingAndRefreshIfNeeded() {
        let now = Date()
        guard let reading = state.reading, !reading.isValid(at: now) else { return }

        cache.clear()
        state = .unavailable(nil)

        scheduleExpirationBoundaryTimer()
        updatePresentation()
        requestRefresh(trigger: .resetBoundary)
    }

    private func handleUnexpectedProcessTermination(_ error: Error) {
        let reason = DisplayErrorReason.classify(error)
        if let reading = state.reading, reading.isValid(at: Date()) {
            state = .stale(reading, reason)
            cache.save(reading)
        } else {
            cache.clear()
            state = .unavailable(reason)
        }
        scheduleExpirationBoundaryTimer()
        updatePresentation()
        scheduleReconnectAttempt()
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
            loginLaunchState: loginItemManager.state
        )
    }

    private func selectLanguage(_ language: AppLanguage) {
        preferences.appLanguage = language
        menuController.setLanguage(language)
        updatePresentation()
    }
}
