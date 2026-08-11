import AppKit

enum WeeklyQuotaDisplayState: Equatable {
    case unavailable(DisplayErrorReason?)
    case stale(WeeklyQuotaReading, DisplayErrorReason?)
    case fresh(WeeklyQuotaReading)

    var reading: WeeklyQuotaReading? {
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

struct StatusItemLayoutSnapshot {
    let buttonBounds: NSRect
    let indicatorBounds: NSRect
    let isAttachedToWindow: Bool
}

struct StatusMenuPresentationSnapshot {
    let indicatorRemainingPercent: Int?
    let language: AppLanguage
    let weeklyTitle: String
    let resetTitle: String
    let updatedTitle: String
    let errorTitle: String?
}

final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let indicatorView: StatusIndicatorView
    private let menu = NSMenu()

    private let weeklyItem = NSMenuItem()
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

    private var state: WeeklyQuotaDisplayState = .unavailable(nil)
    private var refreshing = false
    private var loginLaunchState: LoginLaunchState = .enabled
    private var language: AppLanguage
    private var localization: AppLocalization

    var onRefresh: (() -> Void)?
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
            weeklyTitle: weeklyItem.title,
            resetTitle: resetItem.title,
            updatedTitle: updatedItem.title,
            errorTitle: errorItem.isHidden ? nil : errorItem.title
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
            refreshing: false,
            loginLaunchState: .enabled
        )
    }

    func update(
        state: WeeklyQuotaDisplayState,
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

    func setLanguage(_ language: AppLanguage, now: Date = Date()) {
        self.language = language
        localization = AppLocalization(language: language)
        updateMenuText(now: now)
    }

    @objc private func refreshSelected() {
        onRefresh?()
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

        [weeklyItem, resetItem, updatedItem, errorItem].forEach {
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
        weeklyItem.title = weeklyQuotaTitle(
            reading: state.reading,
            staleSuffix: staleSuffix
        )

        if let reading = state.reading {
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

    private func weeklyQuotaTitle(
        reading: WeeklyQuotaReading?,
        staleSuffix: String
    ) -> String {
        let label = localization.text("menu.weekly_remaining")
        guard let reading else {
            return "\(label)      —"
        }
        return "\(label)      \(reading.remainingPercent)%\(staleSuffix)"
    }
}
