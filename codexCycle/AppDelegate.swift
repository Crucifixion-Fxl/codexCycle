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
        let menuController = StatusMenuController()
        let coordinator = RefreshCoordinator(
            service: service,
            cache: UserDefaultsUsageCache(),
            menuController: menuController,
            loginItemManager: loginItemManager
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
        diagnosticService = service
        let loginState = LoginItemManager(preferences: preferences).state
        print("登录启动: \(loginState == .enabled ? "已启用" : "已禁用")")

        service.fetch { [weak self] result in
            switch result {
            case .success(let reading):
                print("Codex Runtime: \(preferences.selectedCodexPath ?? "—")")
                print("Codex 版本: \(preferences.selectedCodexVersion ?? "—")")
                print("周余量: \(reading.remainingPercent)%")
                print("重置时间戳: \(reading.resetsAt?.timeIntervalSince1970.description ?? "—")")
            case .failure(let error):
                print("诊断失败: \(String(reflecting: error))")
            }
            fflush(stdout)
            self?.diagnosticService = nil
            NSApp.terminate(nil)
        }
    }
}
