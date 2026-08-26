import AppKit

enum QuotaDisplayState: Equatable {
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
    let fiveHourTitle: String
    let fiveHourResetTitle: String
    let weeklyTitle: String
    let weeklyResetTitle: String
    let updatedTitle: String
    let errorTitle: String?
    let requestTitle: String
    let requestIsEnabled: Bool
    let systemLanguageIsSelected: Bool
    let englishLanguageIsSelected: Bool
    let simplifiedChineseLanguageIsSelected: Bool
}

final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let indicatorView: StatusIndicatorView
    private let menu = NSMenu()

    private let fiveHourItem = NSMenuItem()
    private let fiveHourResetItem = NSMenuItem()
    private let weeklyItem = NSMenuItem()
    private let weeklyResetItem = NSMenuItem()
    private let updatedItem = NSMenuItem()
    private let errorItem = NSMenuItem()
    private let refreshItem = NSMenuItem()
    private let requestItem = NSMenuItem()
    private let languageHeaderItem = NSMenuItem()
    private let systemLanguageItem = NSMenuItem()
    private let englishLanguageItem = NSMenuItem()
    private let simplifiedChineseLanguageItem = NSMenuItem()
    private let loginDisabledItem = NSMenuItem()
    private let openLoginSettingsItem = NSMenuItem()
    private let quitItem = NSMenuItem()

    private var state: QuotaDisplayState = .unavailable(nil)
    private var refreshing = false
    private var requesting = false
    private var canRequest = false
    private var loginLaunchState: LoginLaunchState = .enabled
    private var language: AppLanguage
    private var localization: AppLocalization

    var onRefresh: (() -> Void)?
    var onRequest: (() -> Void)?
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
            fiveHourTitle: fiveHourItem.title,
            fiveHourResetTitle: fiveHourResetItem.title,
            weeklyTitle: weeklyItem.title,
            weeklyResetTitle: weeklyResetItem.title,
            updatedTitle: updatedItem.title,
            errorTitle: errorItem.isHidden ? nil : errorItem.title,
            requestTitle: requestItem.title,
            requestIsEnabled: requestItem.isEnabled,
            systemLanguageIsSelected: systemLanguageItem.state == .on,
            englishLanguageIsSelected: englishLanguageItem.state == .on,
            simplifiedChineseLanguageIsSelected:
                simplifiedChineseLanguageItem.state == .on
        )
    }

    init(language: AppLanguage = .system) {
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
            refreshing: false,
            requesting: false,
            canRequest: false,
            loginLaunchState: .enabled
        )
    }

    func update(
        state: QuotaDisplayState,
        refreshing: Bool,
        requesting: Bool = false,
        canRequest: Bool = false,
        loginLaunchState: LoginLaunchState,
        now: Date = Date()
    ) {
        self.state = state
        self.refreshing = refreshing
        self.requesting = requesting
        self.canRequest = canRequest
        self.loginLaunchState = loginLaunchState

        indicatorView.remainingPercent = state.snapshot?.fiveHour?.remainingPercent
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

    @objc private func requestSelected() {
        onRequest?()
    }

    @objc private func systemLanguageSelected() {
        onSelectLanguage?(.system)
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

        [
            fiveHourItem,
            fiveHourResetItem,
            weeklyItem,
            weeklyResetItem,
            updatedItem,
            errorItem
        ].forEach {
            $0.isEnabled = false
            menu.addItem($0)
        }

        menu.addItem(.separator())

        refreshItem.target = self
        refreshItem.action = #selector(refreshSelected)
        menu.addItem(refreshItem)

        requestItem.target = self
        requestItem.action = #selector(requestSelected)
        menu.addItem(requestItem)

        menu.addItem(.separator())

        languageHeaderItem.isEnabled = false
        menu.addItem(languageHeaderItem)

        systemLanguageItem.target = self
        systemLanguageItem.action = #selector(systemLanguageSelected)
        menu.addItem(systemLanguageItem)

        englishLanguageItem.target = self
        englishLanguageItem.action = #selector(englishLanguageSelected)
        menu.addItem(englishLanguageItem)

        simplifiedChineseLanguageItem.target = self
        simplifiedChineseLanguageItem.action = #selector(simplifiedChineseLanguageSelected)
        menu.addItem(simplifiedChineseLanguageItem)

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
        let staleSuffix = state.isStale
            ? localization.text("menu.stale_suffix")
            : ""
        let snapshot = state.snapshot

        fiveHourItem.title = quotaTitle(
            labelKey: "menu.five_hour_remaining",
            reading: snapshot?.fiveHour,
            staleSuffix: staleSuffix
        )
        fiveHourResetItem.title = resetTitle(
            labelKey: "menu.five_hour_reset_countdown",
            reading: snapshot?.fiveHour,
            now: now
        )
        weeklyItem.title = quotaTitle(
            labelKey: "menu.weekly_remaining",
            reading: snapshot?.weekly,
            staleSuffix: staleSuffix
        )
        weeklyResetItem.title = resetTitle(
            labelKey: "menu.weekly_reset_countdown",
            reading: snapshot?.weekly,
            now: now
        )

        if let fetchedAt = snapshot?.latestFetchedAt {
            updatedItem.title = localization.format(
                "menu.last_updated",
                RelativeTimeText.since(
                    fetchedAt,
                    now: now,
                    localization: localization
                )
            )
        } else {
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
        refreshItem.isEnabled = !refreshing && !requesting

        requestItem.title = localization.text(
            requesting ? "menu.requesting" : "menu.request"
        )
        requestItem.isEnabled = canRequest && !refreshing && !requesting

        languageHeaderItem.title = localization.text("menu.language_header")
        systemLanguageItem.title = localization.text("menu.language_system")
        englishLanguageItem.title = localization.text("menu.language_english")
        simplifiedChineseLanguageItem.title = localization.text(
            "menu.language_simplified_chinese"
        )
        systemLanguageItem.state = language == .system ? .on : .off
        englishLanguageItem.state = language == .english ? .on : .off
        simplifiedChineseLanguageItem.state = language == .simplifiedChinese
            ? .on
            : .off

        loginDisabledItem.title = localization.text("menu.login_disabled")
        openLoginSettingsItem.title = localization.text("menu.open_login_settings")
        quitItem.title = localization.text("menu.quit")

        let loginDisabled = loginLaunchState == .disabled
        loginDisabledItem.isHidden = !loginDisabled
        openLoginSettingsItem.isHidden = !loginDisabled
        openLoginSettingsItem.isEnabled = loginDisabled
    }

    private func quotaTitle(
        labelKey: String,
        reading: QuotaUsageReading?,
        staleSuffix: String
    ) -> String {
        let label = localization.text(labelKey)
        guard let reading else {
            return "\(label)      —"
        }
        return "\(label)      \(reading.remainingPercent)%\(staleSuffix)"
    }

    private func resetTitle(
        labelKey: String,
        reading: QuotaUsageReading?,
        now: Date
    ) -> String {
        localization.format(
            labelKey,
            RelativeTimeText.countdown(
                to: reading?.resetsAt,
                now: now,
                localization: localization
            )
        )
    }
}
