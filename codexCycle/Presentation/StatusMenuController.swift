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
    let language: AppLanguage
    let quotaHeaderTitle: String
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
    private let languageHeaderItem = NSMenuItem()
    private let englishLanguageItem = NSMenuItem()
    private let simplifiedChineseLanguageItem = NSMenuItem()
    private let refreshItem = NSMenuItem()
    private let loginDisabledItem = NSMenuItem()
    private let openLoginSettingsItem = NSMenuItem()
    private let quitItem = NSMenuItem()

    private var state: UsageDisplayState = .unavailable(nil)
    private var preferredWindow: QuotaWindow = .fiveHour
    private var refreshing = false
    private var loginLaunchState: LoginLaunchState = .enabled
    private var language: AppLanguage
    private var localization: AppLocalization

    var onRefresh: (() -> Void)?
    var onSelectQuotaWindow: ((QuotaWindow) -> Void)?
    var onSelectLanguage: ((AppLanguage) -> Void)?
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
            language: language,
            quotaHeaderTitle: quotaHeaderItem.title,
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

    init(language: AppLanguage = .english) {
        self.language = language
        localization = AppLocalization(language: language)
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

    func setLanguage(_ language: AppLanguage, now: Date = Date()) {
        self.language = language
        localization = AppLocalization(language: language)
        updateMenuText(now: now)
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

    @objc private func englishLanguageSelected() {
        onSelectLanguage?(.english)
    }

    @objc private func simplifiedChineseLanguageSelected() {
        onSelectLanguage?(.simplifiedChinese)
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

        languageHeaderItem.isEnabled = false
        menu.addItem(languageHeaderItem)

        englishLanguageItem.target = self
        englishLanguageItem.action = #selector(englishLanguageSelected)
        menu.addItem(englishLanguageItem)

        simplifiedChineseLanguageItem.target = self
        simplifiedChineseLanguageItem.action = #selector(simplifiedChineseLanguageSelected)
        menu.addItem(simplifiedChineseLanguageItem)

        menu.addItem(.separator())

        refreshItem.target = self
        refreshItem.action = #selector(refreshSelected)
        menu.addItem(refreshItem)

        loginDisabledItem.isEnabled = false
        loginDisabledItem.isHidden = true
        menu.addItem(loginDisabledItem)

        openLoginSettingsItem.target = self
        openLoginSettingsItem.action = #selector(openLoginSettingsSelected)
        openLoginSettingsItem.isHidden = true
        menu.addItem(openLoginSettingsItem)

        menu.addItem(.separator())

        quitItem.action = #selector(quitSelected)
        quitItem.keyEquivalent = "q"
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func updateMenuText(now: Date) {
        let snapshot = state.snapshot
        let selection = QuotaDisplaySelection(
            preferredWindow: preferredWindow,
            snapshot: snapshot
        )
        quotaHeaderItem.title = localization.text("menu.quota_header")
        languageHeaderItem.title = localization.text("menu.language_header")
        englishLanguageItem.title = localization.text("menu.language_english")
        simplifiedChineseLanguageItem.title = localization.text(
            "menu.language_simplified_chinese"
        )
        englishLanguageItem.state = language == .english ? .on : .off
        simplifiedChineseLanguageItem.state = language == .simplifiedChinese
            ? .on
            : .off

        let staleSuffix = state.isStale
            ? localization.text("menu.stale_suffix")
            : ""
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
            currentViewItem.title = localization.format(
                "menu.current_view",
                current.label,
                preferred.shortLabel
            )
            currentViewItem.isHidden = false
        } else {
            currentViewItem.isHidden = true
        }

        if let reading = selection.currentReading {
            resetItem.title = localization.format(
                "menu.reset_countdown",
                RelativeTimeText.countdown(
                    to: reading.resetsAt,
                    now: now,
                    localization: localization
                )
            )
            updatedItem.title = localization.format(
                "menu.last_updated",
                RelativeTimeText.since(
                    reading.fetchedAt,
                    now: now,
                    localization: localization
                )
            )
        } else {
            resetItem.title = localization.format("menu.reset_countdown", "—")
            updatedItem.title = localization.format("menu.last_updated", "—")
        }

        if let reason = state.errorReason {
            errorItem.title = localization.format(
                "menu.reason",
                localization.text(reason.localizationKey)
            )
            errorItem.isHidden = false
        } else {
            errorItem.isHidden = true
        }

        refreshItem.title = localization.text(
            refreshing ? "menu.refreshing" : "menu.refresh"
        )
        refreshItem.isEnabled = !refreshing

        loginDisabledItem.title = localization.text("menu.login_disabled")
        openLoginSettingsItem.title = localization.text("menu.open_login_settings")
        quitItem.title = localization.text("menu.quit")

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
                label: localization.text("menu.five_hour_remaining"),
                shortLabel: localization.text("menu.five_hour_short")
            )
        case .weekly:
            return QuotaWindowPresentation(
                label: localization.text("menu.weekly_remaining"),
                shortLabel: localization.text("menu.weekly_short")
            )
        }
    }
}
