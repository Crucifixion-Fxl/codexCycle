import AppKit

enum UsageDisplayState: Equatable {
    case unavailable(DisplayErrorReason?)
    case stale(QuotaUsageSnapshot, DisplayErrorReason?)
    case fresh(QuotaUsageSnapshot)

    var snapshot: QuotaUsageSnapshot? {
        switch self {
        case .unavailable:
            return nil
        case .stale(let snapshot, _), .fresh(let snapshot):
            return snapshot
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

struct StatusItemLayoutSnapshot {
    let buttonBounds: NSRect
    let indicatorBounds: NSRect
    let isAttachedToWindow: Bool
}

struct StatusMenuPresentationSnapshot {
    let indicatorRemainingPercent: Int?
    let fiveHourTitle: String
    let weeklyTitle: String
    let fiveHourIsPreferred: Bool
    let weeklyIsPreferred: Bool
    let currentViewTitle: String?
    let resetTitle: String
}

private struct QuotaWindowPresentation {
    let label: String
    let shortLabel: String
}

final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let indicatorView: StatusIndicatorView
    private let menu = NSMenu()

    private let quotaHeaderItem = NSMenuItem()
    private let fiveHourItem = NSMenuItem()
    private let weeklyItem = NSMenuItem()
    private let currentViewItem = NSMenuItem()
    private let resetItem = NSMenuItem()
    private let updatedItem = NSMenuItem()
    private let errorItem = NSMenuItem()
    private let refreshItem = NSMenuItem()
    private let loginDisabledItem = NSMenuItem()
    private let openLoginSettingsItem = NSMenuItem()

    private var state: UsageDisplayState = .unavailable(nil)
    private var preferredWindow: QuotaWindow = .fiveHour
    private var refreshing = false
    private var loginLaunchState: LoginLaunchState = .enabled

    var onRefresh: (() -> Void)?
    var onSelectQuotaWindow: ((QuotaWindow) -> Void)?
    var onOpenLoginSettings: (() -> Void)?

    var layoutSnapshot: StatusItemLayoutSnapshot {
        StatusItemLayoutSnapshot(
            buttonBounds: statusItem.button?.bounds ?? .zero,
            indicatorBounds: indicatorView.bounds,
            isAttachedToWindow: statusItem.button?.window != nil
        )
    }

    var presentationSnapshot: StatusMenuPresentationSnapshot {
        StatusMenuPresentationSnapshot(
            indicatorRemainingPercent: indicatorView.remainingPercent,
            fiveHourTitle: fiveHourItem.title,
            weeklyTitle: weeklyItem.title,
            fiveHourIsPreferred: fiveHourItem.state == .on,
            weeklyIsPreferred: weeklyItem.state == .on,
            currentViewTitle: currentViewItem.isHidden
                ? nil
                : currentViewItem.title,
            resetTitle: resetItem.title
        )
    }

    override init() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: StatusIndicatorMetrics.statusItemWidth
        )
        indicatorView = StatusIndicatorView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: StatusIndicatorMetrics.statusItemWidth,
                height: 22
            )
        )
        super.init()

        configureStatusItem()
        configureMenu()
        update(
            state: .unavailable(nil),
            preferredWindow: .fiveHour,
            refreshing: false,
            loginLaunchState: .enabled
        )
    }

    func update(
        state: UsageDisplayState,
        preferredWindow: QuotaWindow,
        refreshing: Bool,
        loginLaunchState: LoginLaunchState,
        now: Date = Date()
    ) {
        self.state = state
        self.preferredWindow = preferredWindow
        self.refreshing = refreshing
        self.loginLaunchState = loginLaunchState

        let selection = QuotaDisplaySelection(
            preferredWindow: preferredWindow,
            snapshot: state.snapshot
        )
        indicatorView.remainingPercent = selection.currentReading?.remainingPercent
        indicatorView.isStale = state.isStale

        updateMenuText(now: now)
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuText(now: Date())
    }

    @objc private func refreshSelected() {
        onRefresh?()
    }

    @objc private func fiveHourSelected() {
        onSelectQuotaWindow?(.fiveHour)
    }

    @objc private func weeklySelected() {
        onSelectQuotaWindow?(.weekly)
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
        button.image = NSImage(
            size: NSSize(
                width: StatusIndicatorMetrics.statusItemWidth,
                height: 22
            )
        )
        button.imagePosition = .imageOnly
        indicatorView.frame = button.bounds
        indicatorView.autoresizingMask = [.width, .height]
        button.addSubview(indicatorView)
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        quotaHeaderItem.title = "显示限额"
        quotaHeaderItem.isEnabled = false
        menu.addItem(quotaHeaderItem)

        fiveHourItem.target = self
        fiveHourItem.action = #selector(fiveHourSelected)
        fiveHourItem.isEnabled = true
        menu.addItem(fiveHourItem)

        weeklyItem.target = self
        weeklyItem.action = #selector(weeklySelected)
        weeklyItem.isEnabled = true
        menu.addItem(weeklyItem)

        [currentViewItem, resetItem, updatedItem, errorItem].forEach {
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
        let snapshot = state.snapshot
        let selection = QuotaDisplaySelection(
            preferredWindow: preferredWindow,
            snapshot: snapshot
        )
        let staleSuffix = state.isStale ? "（旧数据）" : ""
        let fiveHourPresentation = presentation(for: .fiveHour)
        let weeklyPresentation = presentation(for: .weekly)

        fiveHourItem.title = quotaTitle(
            label: fiveHourPresentation.label,
            reading: snapshot?.fiveHour,
            staleSuffix: staleSuffix
        )
        weeklyItem.title = quotaTitle(
            label: weeklyPresentation.label,
            reading: snapshot?.weekly,
            staleSuffix: staleSuffix
        )
        fiveHourItem.state = preferredWindow == .fiveHour ? .on : .off
        weeklyItem.state = preferredWindow == .weekly ? .on : .off

        if selection.isFallback, let currentWindow = selection.currentWindow {
            let current = presentation(for: currentWindow)
            let preferred = presentation(for: preferredWindow)
            currentViewItem.title = "当前显示      \(current.label)（\(preferred.shortLabel)数据不可用）"
            currentViewItem.isHidden = false
        } else {
            currentViewItem.isHidden = true
        }

        if let reading = selection.currentReading {
            resetItem.title = "重置倒计时    \(RelativeTimeText.countdown(to: reading.resetsAt, now: now))"
            updatedItem.title = "最后更新      \(RelativeTimeText.since(reading.fetchedAt, now: now))"
        } else {
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

    private func quotaTitle(
        label: String,
        reading: QuotaUsageReading?,
        staleSuffix: String
    ) -> String {
        guard let reading else {
            return "\(label)      —"
        }
        return "\(label)      \(reading.remainingPercent)%\(staleSuffix)"
    }

    private func presentation(
        for window: QuotaWindow
    ) -> QuotaWindowPresentation {
        switch window {
        case .fiveHour:
            return QuotaWindowPresentation(
                label: "5 小时余量",
                shortLabel: "5 小时"
            )
        case .weekly:
            return QuotaWindowPresentation(
                label: "周余量",
                shortLabel: "周"
            )
        }
    }
}
