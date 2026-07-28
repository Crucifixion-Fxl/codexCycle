import AppKit
import ServiceManagement

enum LoginLaunchState: Equatable {
    case enabled
    case disabled
}

final class LoginItemManager {
    private let preferences: AppPreferences

    init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    var state: LoginLaunchState {
        SMAppService.mainApp.status == .enabled ? .enabled : .disabled
    }

    func registerOnFirstLaunchIfNeeded() {
        let service = SMAppService.mainApp
        guard service.status == .notRegistered else {
            return
        }
        guard !preferences.attemptedLoginRegistration else {
            return
        }

        preferences.attemptedLoginRegistration = true
        try? service.register()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func unregister() {
        try? SMAppService.mainApp.unregister()
    }
}
