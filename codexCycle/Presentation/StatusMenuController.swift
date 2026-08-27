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

enum RequestFeedbackState: Equatable {
    case idle
    case requesting
    case succeeded
    case failed

    var isRequesting: Bool {
        self == .requesting
    }

    var titleKey: String {
        switch self {
        case .idle:
            return "menu.request"
        case .requesting:
            return "menu.requesting"
        case .succeeded:
            return "menu.request_succeeded"
        case .failed:
            return "menu.request_failed"
        }
    }

    var compactTitleKey: String {
        switch self {
        case .idle:
            return "menu.request_compact"
        case .requesting:
            return "menu.requesting_compact"
        case .succeeded:
            return "menu.request_succeeded_compact"
        case .failed:
            return "menu.request_failed_compact"
        }
    }
}

struct StatusItemLayoutSnapshot {
    let buttonBounds: NSRect
    let indicatorBounds: NSRect
    let isAttachedToWindow: Bool
}

struct StatusPanelLayoutSnapshot {
    let contentSize: NSSize
    let styleMask: NSWindow.StyleMask
    let level: NSWindow.Level
    let isFloatingPanel: Bool
    let hidesOnDeactivate: Bool
    let isVisible: Bool
}

struct HoverExpansionSnapshot {
    let isVisible: Bool
    let text: String?
}

struct StatusMenuPresentationSnapshot {
    let indicatorRemainingPercent: Int?
    let panelRemainingPercent: Int?
    let panelQuotaTitle: String
    let panelResetTitle: String
    let panelSummaryTitle: String
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

final class StatusMenuController: NSObject {
    private let statusItem: NSStatusItem
    private let indicatorView: StatusIndicatorView
    private let panel = NSPanel(
        contentRect: NSRect(
            x: 0,
            y: 0,
            width: UsageMenuMetrics.width,
            height: UsageMenuMetrics.height
        ),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private let menuView = UsageMenuView(
        frame: NSRect(
            x: 0,
            y: 0,
            width: UsageMenuMetrics.width,
            height: UsageMenuMetrics.height
        )
    )

    private var fiveHourTitle = ""
    private var fiveHourResetTitle = ""
    private var weeklyTitle = ""
    private var weeklyResetTitle = ""
    private var updatedTitle = ""
    private var errorTitle: String?
    private var requestTitle = ""
    private var requestIsEnabled = false
    private var panelRemainingPercent: Int?
    private var panelQuotaTitle = ""
    private var panelResetTitle = ""
    private var panelSummaryTitle = ""
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    private var state: QuotaDisplayState = .unavailable(nil)
    private var refreshing = false
    private var requestFeedback: RequestFeedbackState = .idle
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

    var panelLayoutSnapshot: StatusPanelLayoutSnapshot {
        StatusPanelLayoutSnapshot(
            contentSize: panel.contentView?.bounds.size ?? .zero,
            styleMask: panel.styleMask,
            level: panel.level,
            isFloatingPanel: panel.isFloatingPanel,
            hidesOnDeactivate: panel.hidesOnDeactivate,
            isVisible: panel.isVisible
        )
    }

    var hasTruncatedDynamicText: Bool { menuView.hasTruncatedDynamicText }

    var hoverExpansionSnapshot: HoverExpansionSnapshot {
        menuView.hoverExpansionSnapshot
    }

    func simulateQuotaSummaryHoverForTesting() {
        menuView.simulateQuotaSummaryHoverForTesting()
    }

    func simulateQuotaSummaryExitForTesting() {
        menuView.simulateQuotaSummaryExitForTesting()
    }

    func renderedMenuImage() -> NSImage? {
        menuView.layoutSubtreeIfNeeded()
        markNeedsDisplay(menuView)
        guard let representation = menuView.bitmapImageRepForCachingDisplay(
            in: menuView.bounds
        ) else {
            return nil
        }
        menuView.cacheDisplay(in: menuView.bounds, to: representation)
        let image = NSImage(size: menuView.bounds.size)
        image.addRepresentation(representation)
        return image
    }

    private func markNeedsDisplay(_ view: NSView) {
        view.needsDisplay = true
        view.subviews.forEach(markNeedsDisplay)
    }

    var presentationSnapshot: StatusMenuPresentationSnapshot {
        StatusMenuPresentationSnapshot(
            indicatorRemainingPercent: indicatorView.remainingPercent,
            panelRemainingPercent: panelRemainingPercent,
            panelQuotaTitle: panelQuotaTitle,
            panelResetTitle: panelResetTitle,
            panelSummaryTitle: panelSummaryTitle,
            language: language,
            fiveHourTitle: fiveHourTitle,
            fiveHourResetTitle: fiveHourResetTitle,
            weeklyTitle: weeklyTitle,
            weeklyResetTitle: weeklyResetTitle,
            updatedTitle: updatedTitle,
            errorTitle: errorTitle,
            requestTitle: requestTitle,
            requestIsEnabled: requestIsEnabled,
            systemLanguageIsSelected: language == .system,
            englishLanguageIsSelected: language == .english,
            simplifiedChineseLanguageIsSelected: language == .simplifiedChinese
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
        configurePanel()
        installClickOutsideMonitors()
        update(
            state: .unavailable(nil),
            refreshing: false,
            requestFeedback: .idle,
            canRequest: false,
            loginLaunchState: .enabled
        )

#if DEBUG
        if Bundle.main.bundleIdentifier == "com.fxl.codexCycle.preview" {
            DispatchQueue.main.async { [weak self] in
                self?.showPanel()
            }
        }
#endif
    }

    deinit {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
    }

    func update(
        state: QuotaDisplayState,
        refreshing: Bool,
        requestFeedback: RequestFeedbackState = .idle,
        canRequest: Bool = false,
        loginLaunchState: LoginLaunchState,
        now: Date = Date()
    ) {
        self.state = state
        self.refreshing = refreshing
        self.requestFeedback = requestFeedback
        self.canRequest = canRequest
        self.loginLaunchState = loginLaunchState

        indicatorView.remainingPercent = state.snapshot?.fiveHour?.remainingPercent
            ?? state.snapshot?.weekly?.remainingPercent
        indicatorView.isStale = state.isStale
        updateMenuText(now: now)
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

    @objc private func togglePanel() {
        panel.isVisible ? hidePanel() : showPanel()
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
        button.target = self
        button.action = #selector(togglePanel)
    }

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = menuView

        menuView.onRefresh = { [weak self] in self?.refreshSelected() }
        menuView.onRequest = { [weak self] in self?.requestSelected() }
        menuView.onSelectLanguage = { [weak self] selectedLanguage in
            switch selectedLanguage {
            case .system:
                self?.systemLanguageSelected()
            case .english:
                self?.englishLanguageSelected()
            case .simplifiedChinese:
                self?.simplifiedChineseLanguageSelected()
            }
        }
        menuView.onOpenLoginSettings = { [weak self] in
            self?.openLoginSettingsSelected()
        }
        menuView.onQuit = { [weak self] in self?.quitSelected() }
    }

    private func showPanel() {
        updateMenuText(now: Date())
        positionPanel()
        panel.orderFrontRegardless()
    }

    private func hidePanel() {
        menuView.dismissHoverExpansion()
        panel.orderOut(nil)
    }

    private func installClickOutsideMonitors() {
        let mouseEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: mouseEvents
        ) { [weak self] event in
            self?.dismissPanelWhenPointerIsOutside()
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: mouseEvents
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismissPanelWhenPointerIsOutside()
            }
        }
    }

    private func dismissPanelWhenPointerIsOutside() {
        guard panel.isVisible else { return }
        let pointer = NSEvent.mouseLocation
        guard !panel.frame.contains(pointer) else { return }
        guard !statusItemFrameOnScreen().contains(pointer) else { return }
        hidePanel()
    }

    private func statusItemFrameOnScreen() -> NSRect {
        guard
            let button = statusItem.button,
            let window = button.window
        else {
            return .zero
        }
        let frameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }

    private func positionPanel() {
        guard
            let button = statusItem.button,
            let statusWindow = button.window
        else {
            return
        }

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRect = statusWindow.convertToScreen(buttonRectInWindow)
        let screenFrame = statusWindow.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? .zero
        let inset: CGFloat = 8
        let centeredX = buttonRect.midX - UsageMenuMetrics.width / 2
        let x = min(
            max(centeredX, screenFrame.minX + inset),
            screenFrame.maxX - UsageMenuMetrics.width - inset
        )
        let preferredY = buttonRect.minY - UsageMenuMetrics.height - 3
        let y = max(screenFrame.minY + inset, preferredY)

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func updateMenuText(now: Date) {
        let staleSuffix = state.isStale
            ? localization.text("menu.stale_suffix")
            : ""
        let snapshot = state.snapshot

        fiveHourTitle = quotaTitle(
            labelKey: "menu.five_hour_remaining",
            reading: snapshot?.fiveHour,
            staleSuffix: staleSuffix
        )
        fiveHourResetTitle = resetTitle(
            labelKey: "menu.five_hour_reset_countdown",
            reading: snapshot?.fiveHour,
            now: now
        )
        weeklyTitle = quotaTitle(
            labelKey: "menu.weekly_remaining",
            reading: snapshot?.weekly,
            staleSuffix: staleSuffix
        )
        weeklyResetTitle = resetTitle(
            labelKey: "menu.weekly_reset_countdown",
            reading: snapshot?.weekly,
            now: now
        )

        if let fetchedAt = snapshot?.latestFetchedAt {
            updatedTitle = localization.format(
                "menu.last_updated",
                RelativeTimeText.since(
                    fetchedAt,
                    now: now,
                    localization: localization
                )
            )
        } else {
            updatedTitle = localization.format("menu.last_updated", "—")
        }

        if let reason = state.errorReason {
            errorTitle = localization.format(
                "menu.reason",
                localization.text(reason.localizationKey)
            )
        } else {
            errorTitle = nil
        }

        requestTitle = localization.text(requestFeedback.titleKey)
        requestIsEnabled = canRequest && !refreshing && requestFeedback == .idle

        let fiveHourReading = snapshot?.fiveHour
        let weeklyReading = snapshot?.weekly
        let showsFiveHourQuota = fiveHourReading != nil
        let primaryReading = showsFiveHourQuota
            ? fiveHourReading
            : weeklyReading
        let primaryTitleKey = showsFiveHourQuota
            ? "menu.five_hour_remaining"
            : "menu.weekly_remaining"
        let secondaryReading = showsFiveHourQuota
            ? weeklyReading
            : fiveHourReading
        let secondarySummaryKey = showsFiveHourQuota
            ? "menu.weekly_compact"
            : "menu.five_hour_compact"
        let updatedCompact: String
        if let fetchedAt = snapshot?.latestFetchedAt {
            updatedCompact = localization.format(
                "menu.updated_compact",
                RelativeTimeText.since(
                    fetchedAt,
                    now: now,
                    localization: localization
                )
            )
        } else {
            updatedCompact = localization.format("menu.updated_compact", "—")
        }

        panelRemainingPercent = primaryReading?.remainingPercent
        panelQuotaTitle = localization.text(primaryTitleKey)
        panelResetTitle = localization.format(
            "menu.reset_compact",
            RelativeTimeText.countdown(
                to: primaryReading?.resetsAt,
                now: now,
                localization: localization
            )
        )
        panelSummaryTitle = localization.format(
            secondarySummaryKey,
            percentText(secondaryReading),
            RelativeTimeText.countdown(
                to: secondaryReading?.resetsAt,
                now: now,
                localization: localization
            )
        )

        menuView.update(
            remainingPercent: panelRemainingPercent,
            isStale: state.isStale,
            quotaTitle: panelQuotaTitle,
            resetTitle: panelResetTitle,
            quotaSummary: panelSummaryTitle,
            updatedTitle: updatedCompact,
            errorTitle: state.errorReason.map {
                localization.text($0.localizationKey)
            },
            refreshTitle: localization.text(
                refreshing ? "menu.refreshing_compact" : "menu.refresh_compact"
            ),
            refreshIsEnabled: !refreshing && !requestFeedback.isRequesting,
            requestTitle: localization.text(requestFeedback.compactTitleKey),
            requestFeedback: requestFeedback,
            requestIsEnabled: requestIsEnabled,
            language: language,
            languageTitles: [
                localization.text("menu.language_system_compact"),
                localization.text("menu.language_english_compact"),
                localization.text("menu.language_simplified_chinese_compact")
            ],
            loginStatusTitle: localization.text(
                loginLaunchState == .disabled
                    ? "menu.login_disabled"
                    : "menu.login_enabled"
            ),
            openLoginSettingsTitle: localization.text(
                "menu.open_login_settings_compact"
            ),
            quitTitle: localization.text("menu.quit")
        )
    }

    private func percentText(_ reading: QuotaUsageReading?) -> String {
        reading.map { "\($0.remainingPercent)%" } ?? "—"
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

enum UsageMenuMetrics {
    static let width: CGFloat = 300
    static let height: CGFloat = 414
    static let componentInset: CGFloat = 12
    static let componentWidth = width - componentInset * 2
}

private final class UsageMenuView: NSView {
    private let glassContainer = NSView()
    private let chromeView = MenuGlassChromeView()
    private var nativeGlassView: NSView?
    private let gaugeView = QuotaGaugeView()
    private let quotaTitleLabel = UsageMenuView.label(
        font: .systemFont(ofSize: 16.5, weight: .semibold),
        color: .labelColor
    )
    private let resetLabel = UsageMenuView.label(
        font: .systemFont(ofSize: 12.5, weight: .regular),
        color: .secondaryLabelColor
    )
    private let quotaSummaryLabel = UsageMenuView.label(
        font: .systemFont(ofSize: 12.5, weight: .medium),
        color: .secondaryLabelColor
    )
    private let updatedLabel = UsageMenuView.label(
        font: .systemFont(ofSize: 11.5, weight: .regular),
        color: .secondaryLabelColor
    )
    private let errorLabel = UsageMenuView.label(
        font: .systemFont(ofSize: 10, weight: .regular),
        color: .systemRed
    )
    private let refreshButton = UsageMenuView.actionButton(
        symbolName: "arrow.triangle.2.circlepath"
    )
    private let requestButton = UsageMenuView.actionButton(
        symbolName: "doc.badge.plus"
    )
    private let languageControl = LanguageSegmentedControl(
        labels: ["System", "EN", "简中"]
    )
    private let loginDisabledButton = UsageMenuView.rowButton(
        symbolName: "lock"
    )
    private let loginSettingsButton = UsageMenuView.rowButton(
        symbolName: "gearshape"
    )
    private let quitButton = NSButton(title: "", target: nil, action: nil)
    private let shortcutLabel = UsageMenuView.label(
        font: .systemFont(ofSize: 12.3, weight: .regular),
        color: .tertiaryLabelColor
    )
    private let hoverExpansionPresenter = HoverExpansionPresenter()

    var onRefresh: (() -> Void)?
    var onRequest: (() -> Void)?
    var onSelectLanguage: ((AppLanguage) -> Void)?
    var onOpenLoginSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private var dynamicTextLabels: [HoverExpansionTextField] {
        [
            quotaTitleLabel,
            resetLabel,
            quotaSummaryLabel,
            updatedLabel,
            errorLabel
        ]
    }

    var hasTruncatedDynamicText: Bool {
        dynamicTextLabels.contains(where: isTruncated)
    }

    var hoverExpansionSnapshot: HoverExpansionSnapshot {
        hoverExpansionPresenter.snapshot
    }

    func simulateQuotaSummaryHoverForTesting() {
        quotaSummaryLabel.simulateMouseEnteredForTesting()
    }

    func simulateQuotaSummaryExitForTesting() {
        quotaSummaryLabel.simulateMouseExitedForTesting()
    }

    func dismissHoverExpansion() {
        hoverExpansionPresenter.hide()
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = []
        configureGlassBackground()
        chromeView.frame = bounds
        chromeView.autoresizingMask = [.width, .height]
        addSubview(chromeView)
        configureSubviews()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        glassContainer.frame = bounds.insetBy(dx: 1, dy: 1)
        nativeGlassView?.frame = glassContainer.bounds
        nativeGlassView?.layer?.cornerRadius = 14
        if #available(macOS 26.0, *),
           let glass = nativeGlassView as? NSGlassEffectView {
            glass.cornerRadius = 14
        }
        chromeView.frame = bounds
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .contains(.command),
            event.charactersIgnoringModifiers?.lowercased() == "q"
        else {
            return super.performKeyEquivalent(with: event)
        }

        quitSelected()
        return true
    }

    func update(
        remainingPercent: Int?,
        isStale: Bool,
        quotaTitle: String,
        resetTitle: String,
        quotaSummary: String,
        updatedTitle: String,
        errorTitle: String?,
        refreshTitle: String,
        refreshIsEnabled: Bool,
        requestTitle: String,
        requestFeedback: RequestFeedbackState,
        requestIsEnabled: Bool,
        language: AppLanguage,
        languageTitles: [String],
        loginStatusTitle: String,
        openLoginSettingsTitle: String,
        quitTitle: String
    ) {
        gaugeView.remainingPercent = remainingPercent
        gaugeView.isStale = isStale
        quotaTitleLabel.stringValue = quotaTitle
        resetLabel.stringValue = resetTitle
        quotaSummaryLabel.stringValue = quotaSummary
        updatedLabel.stringValue = updatedTitle
        errorLabel.stringValue = errorTitle ?? ""
        errorLabel.isHidden = errorTitle == nil
        updateHoverExpansionText()

        refreshButton.title = refreshTitle
        refreshButton.isEnabled = refreshIsEnabled
        requestButton.title = requestTitle
        requestButton.isEnabled = requestIsEnabled
        updateRequestButtonAppearance(for: requestFeedback)

        for (index, languageTitle) in languageTitles.prefix(3).enumerated() {
            languageControl.setLabel(languageTitle, forSegment: index)
        }
        switch language {
        case .system:
            languageControl.selectedSegment = 0
        case .english:
            languageControl.selectedSegment = 1
        case .simplifiedChinese:
            languageControl.selectedSegment = 2
        }

        loginDisabledButton.title = loginStatusTitle
        loginSettingsButton.title = openLoginSettingsTitle
        quitButton.title = quitTitle
    }

    private func updateRequestButtonAppearance(
        for feedback: RequestFeedbackState
    ) {
        let symbolName: String
        let tintColor: NSColor
        switch feedback {
        case .idle:
            symbolName = "doc.badge.plus"
            tintColor = .labelColor
        case .requesting:
            symbolName = "ellipsis.circle"
            tintColor = .secondaryLabelColor
        case .succeeded:
            symbolName = "checkmark.circle"
            tintColor = NSColor.systemGreen.withAlphaComponent(0.88)
        case .failed:
            symbolName = "exclamationmark.triangle"
            tintColor = NSColor.systemRed.withAlphaComponent(0.84)
        }
        requestButton.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 15.4, weight: .light)
        )
        requestButton.contentTintColor = tintColor
    }

    private func updateHoverExpansionText() {
        hoverExpansionPresenter.hide()
        for label in dynamicTextLabels {
            guard !label.isHidden else {
                label.toolTip = nil
                label.hoverExpansionText = nil
                continue
            }
            label.toolTip = nil
            label.hoverExpansionText = isTruncated(label)
                ? label.stringValue
                : nil
        }
    }

    private func isTruncated(_ label: NSTextField) -> Bool {
        guard !label.isHidden, let cell = label.cell else { return false }
        return !cell.expansionFrame(
            withFrame: label.bounds,
            in: label
        ).isEmpty
    }

    private func configureSubviews() {
        [
            gaugeView,
            quotaTitleLabel,
            resetLabel,
            quotaSummaryLabel,
            updatedLabel,
            errorLabel,
            refreshButton,
            requestButton,
            languageControl,
            loginDisabledButton,
            loginSettingsButton,
            quitButton,
            shortcutLabel
        ].forEach(addSubview)

        for label in dynamicTextLabels {
            label.onHoverChanged = { [weak self, weak label] isHovering in
                guard let self, let label else { return }
                guard isHovering, let text = label.hoverExpansionText else {
                    self.hoverExpansionPresenter.hide()
                    return
                }
                self.hoverExpansionPresenter.show(text: text, from: label)
            }
        }

        gaugeView.frame = NSRect(x: 23, y: 36, width: 82, height: 82)
        quotaTitleLabel.frame = NSRect(x: 116, y: 40, width: 161, height: 24)
        resetLabel.frame = NSRect(x: 116, y: 71, width: 161, height: 18)
        quotaSummaryLabel.frame = NSRect(x: 23, y: 132, width: 254, height: 18)
        updatedLabel.frame = NSRect(x: 23, y: 154, width: 254, height: 16)
        errorLabel.frame = NSRect(x: 23, y: 169, width: 254, height: 13)

        refreshButton.frame = NSRect(x: 17, y: 192, width: 128, height: 32)
        requestButton.frame = NSRect(x: 155, y: 192, width: 128, height: 32)

        languageControl.frame = NSRect(
            x: UsageMenuMetrics.componentInset,
            y: 242,
            width: UsageMenuMetrics.componentWidth,
            height: 32
        )
        languageControl.target = self
        languageControl.action = #selector(languageSelected)

        loginDisabledButton.frame = NSRect(x: 21, y: 288, width: 258, height: 32)
        loginDisabledButton.isInformational = true
        loginSettingsButton.frame = NSRect(x: 21, y: 324, width: 258, height: 32)

        quitButton.frame = NSRect(x: 20, y: 380, width: 212, height: 24)
        quitButton.isBordered = false
        quitButton.alignment = .left
        quitButton.font = .systemFont(ofSize: 13, weight: .regular)
        quitButton.contentTintColor = .labelColor
        quitButton.target = self
        quitButton.action = #selector(quitSelected)
        quitButton.keyEquivalent = "q"
        quitButton.keyEquivalentModifierMask = [.command]

        shortcutLabel.frame = NSRect(x: 242, y: 381, width: 38, height: 22)
        shortcutLabel.stringValue = "⌘ Q"
        shortcutLabel.alignment = .right

        refreshButton.target = self
        refreshButton.action = #selector(refreshSelected)
        requestButton.target = self
        requestButton.action = #selector(requestSelected)
        loginSettingsButton.target = self
        loginSettingsButton.action = #selector(openLoginSettingsSelected)
    }

    @objc private func refreshSelected() {
        onRefresh?()
    }

    @objc private func requestSelected() {
        onRequest?()
    }

    @objc private func languageSelected() {
        let languages: [AppLanguage] = [.system, .english, .simplifiedChinese]
        guard languages.indices.contains(languageControl.selectedSegment) else {
            return
        }
        onSelectLanguage?(languages[languageControl.selectedSegment])
    }

    @objc private func openLoginSettingsSelected() {
        onOpenLoginSettings?()
    }

    @objc private func quitSelected() {
        onQuit?()
    }

    private func configureGlassBackground() {
        glassContainer.wantsLayer = true
        glassContainer.layer?.cornerRadius = 14
        glassContainer.layer?.masksToBounds = true
        addSubview(glassContainer)

        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            glassContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            return
        }

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: glassContainer.bounds)
            glass.style = .clear
            glass.cornerRadius = 14
            glass.tintColor = NSColor(
                calibratedRed: 0.055,
                green: 0.064,
                blue: 0.078,
                alpha: 0.84
            )
            glass.autoresizingMask = [.width, .height]
            glassContainer.addSubview(glass)
            nativeGlassView = glass
        } else {
            let effect = NSVisualEffectView(frame: glassContainer.bounds)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 14
            effect.layer?.masksToBounds = true
            effect.autoresizingMask = [.width, .height]
            glassContainer.addSubview(effect)
            nativeGlassView = effect
        }
    }

    private static func label(
        font: NSFont,
        color: NSColor
    ) -> HoverExpansionTextField {
        let field = HoverExpansionTextField(labelWithString: "")
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        return field
    }

    private static func symbolButton(
        symbolName: String,
        pointSize: CGFloat
    ) -> NSButton {
        let button = NSButton(image: NSImage(), target: nil, action: nil)
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: pointSize, weight: .light)
        )
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    private static func actionButton(symbolName: String) -> NSButton {
        let button = symbolButton(symbolName: symbolName, pointSize: 15.4)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.font = .systemFont(ofSize: 13.5, weight: .regular)
        button.contentTintColor = .labelColor
        return button
    }

    private static func rowButton(symbolName: String) -> MenuRowButton {
        MenuRowButton(symbolName: symbolName)
    }
}

private final class HoverExpansionTextField: NSTextField {
    var hoverExpansionText: String?
    var onHoverChanged: ((Bool) -> Void)?

    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard hoverExpansionText != nil else { return }
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false)
    }

    func simulateMouseEnteredForTesting() {
        guard hoverExpansionText != nil else { return }
        onHoverChanged?(true)
    }

    func simulateMouseExitedForTesting() {
        onHoverChanged?(false)
    }
}

private final class HoverExpansionPresenter {
    private let panel: NSPanel
    private let bubbleView = NSView()
    private let textLabel = NSTextField(labelWithString: "")
    private weak var parentWindow: NSWindow?
    private var presentedText: String?

    var snapshot: HoverExpansionSnapshot {
        HoverExpansionSnapshot(
            isVisible: panel.isVisible,
            text: presentedText
        )
    }

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = NSWindow.Level(
            rawValue: NSWindow.Level.popUpMenu.rawValue + 1
        )
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient
        ]

        bubbleView.wantsLayer = true
        bubbleView.layer?.cornerRadius = 7
        bubbleView.layer?.backgroundColor = NSColor(
            calibratedWhite: 0.10,
            alpha: 0.98
        ).cgColor
        bubbleView.layer?.borderColor = NSColor.white
            .withAlphaComponent(0.18).cgColor
        bubbleView.layer?.borderWidth = 0.75

        textLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
        textLabel.textColor = .white
        textLabel.lineBreakMode = .byClipping
        textLabel.maximumNumberOfLines = 1
        bubbleView.addSubview(textLabel)
        panel.contentView = bubbleView
    }

    deinit {
        hide()
    }

    func show(text: String, from sourceView: NSView) {
        presentedText = text
        textLabel.stringValue = text

        let textSize = textLabel.attributedStringValue.size()
        let panelSize = NSSize(
            width: ceil(textSize.width) + 24,
            height: 30
        )
        bubbleView.frame = NSRect(origin: .zero, size: panelSize)
        textLabel.frame = NSRect(
            x: 12,
            y: 6,
            width: ceil(textSize.width),
            height: 18
        )
        panel.setContentSize(panelSize)

        guard let sourceWindow = sourceView.window else { return }
        let sourceFrame = sourceWindow.convertToScreen(
            sourceView.convert(sourceView.bounds, to: nil)
        )
        let visibleFrame = sourceWindow.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? sourceFrame
        let minimumX = visibleFrame.minX + 8
        let maximumX = visibleFrame.maxX - panelSize.width - 8
        let centeredX = sourceFrame.midX - panelSize.width / 2
        let originX = min(max(centeredX, minimumX), maximumX)
        var originY = sourceFrame.minY - panelSize.height - 6
        if originY < visibleFrame.minY + 8 {
            originY = sourceFrame.maxY + 6
        }

        if parentWindow !== sourceWindow {
            if let parentWindow {
                parentWindow.removeChildWindow(panel)
            }
            sourceWindow.addChildWindow(panel, ordered: .above)
            parentWindow = sourceWindow
        }
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        panel.orderFrontRegardless()
    }

    func hide() {
        presentedText = nil
        if let parentWindow {
            parentWindow.removeChildWindow(panel)
        }
        parentWindow = nil
        panel.orderOut(nil)
    }
}

private final class MenuGlassChromeView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSGraphicsContext.saveGraphicsState()
        let surfaceRect = bounds.insetBy(dx: 1, dy: 1)
        let surfacePath = NSBezierPath(
            roundedRect: surfaceRect,
            xRadius: 14,
            yRadius: 14
        )
        surfacePath.addClip()

        NSGradient(
            colorsAndLocations:
                (graphite(red: 0.085, green: 0.098, blue: 0.118, alpha: 0.91), 0),
                (graphite(red: 0.055, green: 0.064, blue: 0.079, alpha: 0.93), 0.34),
                (graphite(red: 0.034, green: 0.040, blue: 0.051, alpha: 0.95), 0.72),
                (graphite(red: 0.019, green: 0.023, blue: 0.030, alpha: 0.97), 1)
        )?.draw(in: bounds, angle: -90)

        let glowRect = NSRect(
            x: -bounds.width * 0.18,
            y: -bounds.height * 0.16,
            width: bounds.width * 0.92,
            height: bounds.height * 0.48
        )
        NSGradient(
            starting: NSColor(
                calibratedRed: 0.54,
                green: 0.64,
                blue: 0.76,
                alpha: 0.045
            ),
            ending: .clear
        )?.draw(in: glowRect, relativeCenterPosition: NSPoint(x: -0.1, y: -0.15))

        drawGlassCard(
            NSRect(
                x: UsageMenuMetrics.componentInset,
                y: 19,
                width: UsageMenuMetrics.componentWidth,
                height: 161
            ),
            radius: 12,
            topAlpha: 0.048,
            bottomAlpha: 0.014
        )
        drawGlassCard(
            NSRect(
                x: UsageMenuMetrics.componentInset,
                y: 188,
                width: UsageMenuMetrics.componentWidth,
                height: 40
            ),
            radius: 10,
            topAlpha: 0.044,
            bottomAlpha: 0.012
        )
        drawGlassCard(
            NSRect(
                x: UsageMenuMetrics.componentInset,
                y: 284,
                width: UsageMenuMetrics.componentWidth,
                height: 76
            ),
            radius: 10,
            topAlpha: 0.034,
            bottomAlpha: 0.009
        )
        NSGraphicsContext.restoreGraphicsState()

        surfacePath.lineWidth = 1
        NSColor.white.withAlphaComponent(0.115).setStroke()
        surfacePath.stroke()

        let topHighlight = NSBezierPath()
        topHighlight.move(to: NSPoint(x: 15, y: 1.5))
        topHighlight.line(to: NSPoint(x: bounds.width - 15, y: 1.5))
        topHighlight.lineWidth = 0.8
        NSColor.white.withAlphaComponent(0.20).setStroke()
        topHighlight.stroke()

        let separatorColor = NSColor.white.withAlphaComponent(0.105)
        separatorColor.setStroke()
        drawLine(
            from: NSPoint(x: 22, y: 123),
            to: NSPoint(x: bounds.width - 22, y: 123)
        )
        drawLine(
            from: NSPoint(x: bounds.midX, y: 196),
            to: NSPoint(x: bounds.midX, y: 220)
        )
        drawLine(
            from: NSPoint(x: 21, y: 322),
            to: NSPoint(x: bounds.width - 21, y: 322)
        )
    }

    private func drawLine(from start: NSPoint, to end: NSPoint) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = 0.8
        path.stroke()
    }

    private func graphite(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        alpha: CGFloat
    ) -> NSColor {
        NSColor(
            calibratedRed: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }

    private func drawGlassCard(
        _ rect: NSRect,
        radius: CGFloat,
        topAlpha: CGFloat,
        bottomAlpha: CGFloat
    ) {
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: radius,
            yRadius: radius
        )
        NSGradient(
            starting: NSColor.white.withAlphaComponent(topAlpha),
            ending: NSColor.white.withAlphaComponent(bottomAlpha)
        )?.draw(in: path, angle: -90)
        NSColor.white.withAlphaComponent(0.078).setStroke()
        path.lineWidth = 0.7
        path.stroke()

        let highlight = NSBezierPath()
        highlight.move(to: NSPoint(x: rect.minX + radius, y: rect.minY + 0.8))
        highlight.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY + 0.8))
        highlight.lineWidth = 0.6
        NSColor.white.withAlphaComponent(0.105).setStroke()
        highlight.stroke()
    }
}

final class LanguageSegmentedControl: NSControl {
    private var labels: [String]
    private var selectedSegmentStorage = 0

    var selectedSegment: Int {
        get { selectedSegmentStorage }
        set { setSelectedSegment(newValue, animated: false) }
    }

    @objc dynamic private(set) var selectionPosition: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    init(labels: [String]) {
        self.labels = labels
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override class func defaultAnimation(
        forKey key: NSAnimatablePropertyKey
    ) -> Any? {
        if key == "selectionPosition" {
            return CABasicAnimation()
        }
        return super.defaultAnimation(forKey: key)
    }

    func setSelectedSegment(
        _ segment: Int,
        animated: Bool,
        reduceMotion: Bool? = nil
    ) {
        guard !labels.isEmpty else { return }
        let target = min(labels.count - 1, max(0, segment))
        guard target != selectedSegmentStorage else { return }

        selectedSegmentStorage = target
        let targetPosition = CGFloat(target)
        let shouldReduceMotion = reduceMotion
            ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !shouldReduceMotion else {
            selectionPosition = targetPosition
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.22,
                0.78,
                0.24,
                1
            )
            animator().selectionPosition = targetPosition
        }
    }

    func setLabel(_ label: String, forSegment segment: Int) {
        guard labels.indices.contains(segment) else { return }
        labels[segment] = label
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let outerRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let outerPath = NSBezierPath(
            roundedRect: outerRect,
            xRadius: 7,
            yRadius: 7
        )
        NSColor.white.withAlphaComponent(0.045).setFill()
        outerPath.fill()
        NSColor.white.withAlphaComponent(0.20).setStroke()
        outerPath.lineWidth = 1
        outerPath.stroke()

        let segmentWidth = bounds.width / CGFloat(max(1, labels.count))
        if labels.indices.contains(selectedSegment) {
            let selectedRect = NSRect(
                x: selectionPosition * segmentWidth + 2,
                y: 2,
                width: segmentWidth - 4,
                height: bounds.height - 4
            )
            let selectedPath = NSBezierPath(
                roundedRect: selectedRect,
                xRadius: 6,
                yRadius: 6
            )
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: 1)
            shadow.set()
            NSGradient(
                starting: NSColor(
                    calibratedRed: 0.18,
                    green: 0.22,
                    blue: 0.29,
                    alpha: 0.90
                ),
                ending: NSColor(
                    calibratedRed: 0.085,
                    green: 0.105,
                    blue: 0.145,
                    alpha: 0.92
                )
            )?.draw(in: selectedPath, angle: -90)
            NSShadow().set()
            NSColor.white.withAlphaComponent(0.18).setStroke()
            selectedPath.lineWidth = 0.8
            selectedPath.stroke()

            let selectedHighlight = NSBezierPath()
            selectedHighlight.move(
                to: NSPoint(x: selectedRect.minX + 6, y: selectedRect.minY + 1)
            )
            selectedHighlight.line(
                to: NSPoint(x: selectedRect.maxX - 6, y: selectedRect.minY + 1)
            )
            selectedHighlight.lineWidth = 0.7
            NSColor.white.withAlphaComponent(0.22).setStroke()
            selectedHighlight.stroke()
        }

        NSColor.labelColor.withAlphaComponent(0.12).setStroke()
        let visualSegment = Int(selectionPosition.rounded())
        for index in 1..<labels.count where index != visualSegment
            && index != visualSegment + 1 {
            let x = CGFloat(index) * segmentWidth
            let separator = NSBezierPath()
            separator.move(to: NSPoint(x: x, y: 5))
            separator.line(to: NSPoint(x: x, y: bounds.height - 5))
            separator.lineWidth = 1
            separator.stroke()
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        for (index, label) in labels.enumerated() {
            let emphasis = max(
                0,
                1 - abs(CGFloat(index) - selectionPosition)
            )
            let textColor = NSColor.secondaryLabelColor.blended(
                withFraction: emphasis,
                of: .labelColor
            ) ?? NSColor.labelColor
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.6, weight: .regular),
                .foregroundColor: textColor,
                .paragraphStyle: paragraph
            ]
            let text = NSAttributedString(string: label, attributes: attributes)
            let textSize = text.size()
            text.draw(
                in: NSRect(
                    x: CGFloat(index) * segmentWidth,
                    y: bounds.midY - textSize.height / 2,
                    width: segmentWidth,
                    height: textSize.height
                )
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location), !labels.isEmpty else { return }
        let segmentWidth = bounds.width / CGFloat(labels.count)
        setSelectedSegment(
            min(
            labels.count - 1,
            max(0, Int(location.x / segmentWidth))
            ),
            animated: true
        )
        sendAction(action, to: target)
    }
}

private final class MenuRowButton: NSButton {
    private let symbol: NSImage?
    var isInformational = false {
        didSet { needsDisplay = true }
    }

    init(symbolName: String) {
        symbol = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 15.4, weight: .light)
        )
        super.init(frame: .zero)
        isBordered = false
        alignment = .left
        font = .systemFont(ofSize: 13, weight: .regular)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted && !isInformational {
            let highlightPath = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 1, dy: 1),
                xRadius: 4,
                yRadius: 4
            )
            NSColor.white.withAlphaComponent(0.10).setFill()
            highlightPath.fill()
            NSColor.white.withAlphaComponent(0.16).setStroke()
            highlightPath.lineWidth = 0.7
            highlightPath.stroke()
        }

        let tint = isInformational ? NSColor.secondaryLabelColor : NSColor.labelColor
        if let symbol {
            let imageRect = NSRect(x: 2, y: 4, width: 17, height: 17)
            symbol.draw(in: imageRect)
            tint.setFill()
            imageRect.fill(using: .sourceAtop)
        }

        let text = NSAttributedString(
            string: title,
            attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: tint
            ]
        )
        let textSize = text.size()
        text.draw(
            at: NSPoint(
                x: 29,
                y: bounds.midY - textSize.height / 2
            )
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInformational ? nil : super.hitTest(point)
    }
}

private final class QuotaGaugeView: NSView {
    var remainingPercent: Int? {
        didSet { needsDisplay = true }
    }

    var isStale = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let lineWidth: CGFloat = 3
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - lineWidth
        let diskRect = NSRect(
            x: center.x - radius + lineWidth,
            y: center.y - radius + lineWidth,
            width: (radius - lineWidth) * 2,
            height: (radius - lineWidth) * 2
        )
        NSGradient(
            starting: NSColor.white.withAlphaComponent(0.040),
            ending: NSColor.black.withAlphaComponent(0.055)
        )?.draw(in: NSBezierPath(ovalIn: diskRect), angle: -90)

        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setStrokeColor(
            NSColor.labelColor.withAlphaComponent(0.12).cgColor
        )
        context.addEllipse(
            in: NSRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
        context.strokePath()

        if let remainingPercent, remainingPercent > 0 {
            let normalized = min(1, max(0, CGFloat(remainingPercent) / 100))
            context.setStrokeColor(
                (isStale
                    ? NSColor.secondaryLabelColor.withAlphaComponent(0.72)
                    : NSColor(
                        calibratedRed: 0.30,
                        green: 0.86,
                        blue: 0.47,
                        alpha: 1
                    )
                ).cgColor
            )
            context.addArc(
                center: center,
                radius: radius,
                startAngle: -.pi / 2,
                endAngle: -.pi / 2 + .pi * 2 * normalized,
                clockwise: false
            )
            context.strokePath()
        }

        let value = remainingPercent.map { "\($0)%" } ?? "—"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(
            string: value,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: 18,
                    weight: .medium
                ),
                .foregroundColor: isStale
                    ? NSColor.secondaryLabelColor
                    : NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )
        let size = text.size()
        text.draw(
            at: NSPoint(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2
            )
        )
    }
}
