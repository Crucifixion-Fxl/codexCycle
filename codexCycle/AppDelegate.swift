import AppKit
import OSLog

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.fxl.codexCycle", category: "lifecycle")
    private var coordinator: RefreshCoordinator?
    private var loginItemManager: LoginItemManager?
    private var diagnosticService: CodexUsageService?

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.notice("Application finished launching")
        NSApp.setActivationPolicy(.accessory)

        if NSClassFromString("XCTestCase") != nil {
            logger.notice("XCTest host detected")
            return
        }

        let preferences = AppPreferences()
        let loginItemManager = LoginItemManager(preferences: preferences)
        self.loginItemManager = loginItemManager

        if ProcessInfo.processInfo.arguments.contains("--unregister-login-item") {
            loginItemManager.unregister()
            NSApp.terminate(nil)
            return
        }

        if ProcessInfo.processInfo.arguments.contains("--diagnose") {
            logger.notice("Running CLI diagnostic")
            runDiagnostic(preferences: preferences)
            return
        }

        if SingleInstanceGuard.isAnotherInstanceRunning {
            logger.notice("Another application instance is already running")
            NSApp.terminate(nil)
            return
        }

        let locator = CodexLocator(preferences: preferences)
        let service = CodexUsageService(locator: locator, preferences: preferences)
        let menuController = StatusMenuController(language: preferences.appLanguage)
        let coordinator = RefreshCoordinator(
            service: service,
            cache: UserDefaultsUsageCache(),
            menuController: menuController,
            loginItemManager: loginItemManager,
            preferences: preferences
        )

        self.coordinator = coordinator
        logger.notice("Starting refresh coordinator")
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        diagnosticService?.stop()
    }

    private func runDiagnostic(preferences: AppPreferences) {
        let locator = CodexLocator(preferences: preferences)
        let service = CodexUsageService(locator: locator, preferences: preferences)
        let localization = AppLocalization(language: preferences.appLanguage)
        diagnosticService = service
        let loginState = LoginItemManager(preferences: preferences).state
        let loginStateText = localization.text(
            loginState == .enabled ? "diagnostic.enabled" : "diagnostic.disabled"
        )
        print("\(localization.text("diagnostic.login_launch")): \(loginStateText)")

        service.fetch { [weak self] result in
            switch result {
            case .success(let snapshot):
                print(
                    "\(localization.text("diagnostic.runtime")): "
                        + "\(preferences.selectedCodexPath ?? "—")"
                )
                print(
                    "\(localization.text("diagnostic.runtime_version")): "
                        + "\(preferences.selectedCodexVersion ?? "—")"
                )
                print(
                    "\(localization.text("diagnostic.five_hour_remaining")): "
                        + "\(snapshot.fiveHour.map { "\($0.remainingPercent)%" } ?? "—")"
                )
                print(
                    "\(localization.text("diagnostic.five_hour_reset")): "
                        + "\(snapshot.fiveHour?.resetsAt?.timeIntervalSince1970.description ?? "—")"
                )
                print(
                    "\(localization.text("diagnostic.weekly_remaining")): "
                        + "\(snapshot.weekly.map { "\($0.remainingPercent)%" } ?? "—")"
                )
                print(
                    "\(localization.text("diagnostic.weekly_reset")): "
                        + "\(snapshot.weekly?.resetsAt?.timeIntervalSince1970.description ?? "—")"
                )
            case .failure(let error):
                print(
                    "\(localization.text("diagnostic.failure")): \(String(reflecting: error))"
                )
            }
            fflush(stdout)
            self?.diagnosticService = nil
            NSApp.terminate(nil)
        }
    }
}
