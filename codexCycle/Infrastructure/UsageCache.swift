import Foundation

protocol UsageCaching {
    func load(now: Date) -> WeeklyUsageReading?
    func save(_ reading: WeeklyUsageReading)
    func clear()
}

final class UserDefaultsUsageCache: UsageCaching {
    private enum Key {
        static let remainingPercent = "usage.remainingPercent"
        static let resetsAt = "usage.resetsAt"
        static let fetchedAt = "usage.fetchedAt"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(now: Date = Date()) -> WeeklyUsageReading? {
        guard
            defaults.object(forKey: Key.remainingPercent) != nil,
            let resetsAt = defaults.object(forKey: Key.resetsAt) as? Date,
            let fetchedAt = defaults.object(forKey: Key.fetchedAt) as? Date,
            resetsAt > now
        else {
            clear()
            return nil
        }

        return WeeklyUsageReading(
            remainingPercent: defaults.integer(forKey: Key.remainingPercent),
            resetsAt: resetsAt,
            fetchedAt: fetchedAt
        )
    }

    func save(_ reading: WeeklyUsageReading) {
        guard let resetsAt = reading.resetsAt else {
            return
        }

        defaults.set(reading.remainingPercent, forKey: Key.remainingPercent)
        defaults.set(resetsAt, forKey: Key.resetsAt)
        defaults.set(reading.fetchedAt, forKey: Key.fetchedAt)
    }

    func clear() {
        defaults.removeObject(forKey: Key.remainingPercent)
        defaults.removeObject(forKey: Key.resetsAt)
        defaults.removeObject(forKey: Key.fetchedAt)
    }
}

final class AppPreferences {
    private enum Key {
        static let codexPath = "codex.path"
        static let codexVersion = "codex.version"
        static let attemptedLoginRegistration = "launchAtLogin.registrationAttempted"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedCodexPath: String? {
        get { defaults.string(forKey: Key.codexPath) }
        set { defaults.set(newValue, forKey: Key.codexPath) }
    }

    var selectedCodexVersion: String? {
        get { defaults.string(forKey: Key.codexVersion) }
        set { defaults.set(newValue, forKey: Key.codexVersion) }
    }

    var attemptedLoginRegistration: Bool {
        get { defaults.bool(forKey: Key.attemptedLoginRegistration) }
        set { defaults.set(newValue, forKey: Key.attemptedLoginRegistration) }
    }
}
