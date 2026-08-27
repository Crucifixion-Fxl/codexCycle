import AppKit
import OSLog
import ServiceManagement

enum LoginLaunchState: Equatable {
    case enabled
    case disabled
}

protocol LoginItemServicing: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemServicing {}

final class LoginItemManager {
    private let preferences: AppPreferences
    private let service: LoginItemServicing
    private let logger = Logger(
        subsystem: "com.fxl.codexCycle",
        category: "login-item"
    )

    init(
        preferences: AppPreferences,
        service: LoginItemServicing = SMAppService.mainApp
    ) {
        self.preferences = preferences
        self.service = service
    }

    var state: LoginLaunchState {
        service.status == .enabled ? .enabled : .disabled
    }

    func registerOnFirstLaunchIfNeeded() {
        guard service.status == .notRegistered else {
            return
        }
        guard !preferences.attemptedLoginRegistration else {
            return
        }

        preferences.attemptedLoginRegistration = true
        try? service.register()
    }

    @discardableResult
    func setEnabled(_ isEnabled: Bool) -> LoginLaunchState {
        preferences.attemptedLoginRegistration = true
        do {
            if isEnabled {
                guard service.status != .enabled else { return .enabled }
                try service.register()
            } else {
                guard service.status != .notRegistered else { return .disabled }
                try service.unregister()
            }
        } catch {
            logger.error(
                "Failed to set launch at login to \(isEnabled, privacy: .public): \(String(reflecting: error), privacy: .public)"
            )
        }
        return state
    }

    func unregister() {
        try? service.unregister()
    }
}
