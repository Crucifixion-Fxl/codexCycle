import AppKit

enum SingleInstanceGuard {
    static var isAnotherInstanceRunning: Bool {
        guard let identifier = Bundle.main.bundleIdentifier else {
            return false
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .contains { $0.processIdentifier != currentPID }
    }
}
