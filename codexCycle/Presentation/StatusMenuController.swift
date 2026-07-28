import AppKit

enum UsageDisplayState: Equatable {
    case unavailable(DisplayErrorReason?)
    case stale(WeeklyUsageReading, DisplayErrorReason?)
    case fresh(WeeklyUsageReading)

    var reading: WeeklyUsageReading? {
        switch self {
        case .unavailable:
            return nil
        case .stale(let reading, _), .fresh(let reading):
            return reading
        }
    }

    var isStale: Bool {
        switch self {
        case .fresh:
            return false
        case .unavailable, .stale:
            return true
        }
    }

    var errorReason: DisplayErrorReason? {
        switch self {
        case .unavailable(let reason), .stale(_, let reason):
            return reason
        case .fresh:
            return nil
        }
    }
}

final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let indicatorView: StatusIndicatorView
    private let menu = NSMenu()

    private let weeklyItem = NSMenuItem()
    private let resetItem = NSMenuItem()
    private let updatedItem = NSMenuItem()
    private let errorItem = NSMenuItem()
    private let refreshItem = NSMenuItem()
    private let loginDisabledItem = NSMenuItem()
    private let openLoginSettingsItem = NSMenuItem()

    private var state: UsageDisplayState = .unavailable(nil)
    private var refreshing = false
    private var loginLaunchState: LoginLaunchState = .enabled

    var onRefresh: (() -> Void)?
    var onOpenLoginSettings: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: 26)
        indicatorView = StatusIndicatorView(frame: NSRect(x: 0, y: 0, width: 26, height: 22))
        super.init()

        configureStatusItem()
        configureMenu()
        update(state: .unavailable(nil), refreshing: false, loginLaunchState: .enabled)
    }

    func update(
        state: UsageDisplayState,
        refreshing: Bool,
        loginLaunchState: LoginLaunchState,
        now: Date = Date()
    ) {
        self.state = state
        self.refreshing = refreshing
        self.loginLaunchState = loginLaunchState

        indicatorView.remainingPercent = state.reading?.remainingPercent
        indicatorView.isStale = state.isStale

        updateMenuText(now: now)
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuText(now: Date())
    }

    @objc private func refreshSelected() {
        onRefresh?()
    }

    @objc private func openLoginSettingsSelected() {
        onOpenLoginSettings?()
    }

    @objc private func quitSelected() {
        NSApp.terminate(nil)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = nil
        indicatorView.frame = button.bounds
        indicatorView.autoresizingMask = [.width, .height]
        button.addSubview(indicatorView)
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        [weeklyItem, resetItem, updatedItem, errorItem].forEach {
            $0.isEnabled = false
            menu.addItem($0)
        }

        menu.addItem(.separator())

        refreshItem.title = "立即刷新"
        refreshItem.target = self
        refreshItem.action = #selector(refreshSelected)
        menu.addItem(refreshItem)

        loginDisabledItem.title = "登录启动已禁用"
        loginDisabledItem.isEnabled = false
        loginDisabledItem.isHidden = true
        menu.addItem(loginDisabledItem)

        openLoginSettingsItem.title = "打开登录项设置…"
        openLoginSettingsItem.target = self
        openLoginSettingsItem.action = #selector(openLoginSettingsSelected)
        openLoginSettingsItem.isHidden = true
        menu.addItem(openLoginSettingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 codexCycle",
            action: #selector(quitSelected),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func updateMenuText(now: Date) {
        if let reading = state.reading {
            let staleSuffix = state.isStale ? "（旧数据）" : ""
            weeklyItem.title = "周余量        \(reading.remainingPercent)%\(staleSuffix)"
            resetItem.title = "重置倒计时    \(RelativeTimeText.countdown(to: reading.resetsAt, now: now))"
            updatedItem.title = "最后更新      \(RelativeTimeText.since(reading.fetchedAt, now: now))"
        } else {
            weeklyItem.title = "周余量        —"
            resetItem.title = "重置倒计时    —"
            updatedItem.title = "最后更新      —"
        }

        if let reason = state.errorReason {
            errorItem.title = "原因          \(reason.rawValue)"
            errorItem.isHidden = false
        } else {
            errorItem.isHidden = true
        }

        refreshItem.title = refreshing ? "正在刷新…" : "立即刷新"
        refreshItem.isEnabled = !refreshing

        let loginDisabled = loginLaunchState == .disabled
        loginDisabledItem.isHidden = !loginDisabled
        openLoginSettingsItem.isHidden = !loginDisabled
        openLoginSettingsItem.isEnabled = loginDisabled
    }
}
