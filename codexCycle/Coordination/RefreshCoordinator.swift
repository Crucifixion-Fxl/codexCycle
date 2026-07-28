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
    private let cache: UsageCaching
    private let menuController: StatusMenuController
    private let loginItemManager: LoginItemManager
    private let logger = Logger(subsystem: "com.fxl.codexCycle", category: "refresh")

    private var state: UsageDisplayState = .unavailable(nil)
    private var refreshing = false
    private var pollTimer: Timer?
    private var relativeTimer: Timer?
    private var resetBoundaryTimer: Timer?
    private var reconnectTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var reconnectAttempt = 0
    private let reconnectDelays: [TimeInterval] = [1, 5, 30, 300]

    init(
        service: CodexUsageService,
        cache: UsageCaching,
        menuController: StatusMenuController,
        loginItemManager: LoginItemManager
    ) {
        self.service = service
        self.cache = cache
        self.menuController = menuController
        self.loginItemManager = loginItemManager
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))

        loginItemManager.registerOnFirstLaunchIfNeeded()

        if let cached = cache.load(now: Date()) {
            state = .stale(cached, nil)
            scheduleResetBoundaryTimer(for: cached)
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
        resetBoundaryTimer?.invalidate()
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
                if let reading = self.state.reading,
                   reading.resetsAt.map({ $0 > Date() }) != false {
                    self.state = .stale(reading, reason)
                } else {
                    self.cache.clear()
                    self.state = .unavailable(reason)
                }

                if case .processRecovery = trigger {
                    self.scheduleReconnectAttempt()
                }
            }

            self.scheduleResetBoundaryTimer(for: self.state.reading)
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

    private func scheduleResetBoundaryTimer(for reading: WeeklyUsageReading?) {
        resetBoundaryTimer?.invalidate()
        resetBoundaryTimer = nil

        guard let resetsAt = reading?.resetsAt else {
            return
        }

        let delay = max(0.05, resetsAt.timeIntervalSinceNow + 0.05)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.resetBoundaryTimer = nil
            self.invalidateExpiredReadingAndRefreshIfNeeded()
            if let currentReading = self.state.reading,
               currentReading.resetsAt.map({ $0 > Date() }) == true {
                self.scheduleResetBoundaryTimer(for: currentReading)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        resetBoundaryTimer = timer
    }

    private func invalidateExpiredReadingAndRefreshIfNeeded() {
        guard
            let reading = state.reading,
            let resetsAt = reading.resetsAt,
            resetsAt <= Date()
        else {
            return
        }

        cache.clear()
        state = .unavailable(nil)
        resetBoundaryTimer?.invalidate()
        resetBoundaryTimer = nil
        updatePresentation()
        requestRefresh(trigger: .resetBoundary)
    }

    private func handleUnexpectedProcessTermination(_ error: Error) {
        let reason = DisplayErrorReason.classify(error)
        if let reading = state.reading,
           reading.resetsAt.map({ $0 > Date() }) != false {
            state = .stale(reading, reason)
        } else {
            cache.clear()
            state = .unavailable(reason)
        }
        scheduleResetBoundaryTimer(for: state.reading)
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
}
