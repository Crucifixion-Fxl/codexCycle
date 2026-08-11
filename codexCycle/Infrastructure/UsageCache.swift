import Foundation

protocol WeeklyQuotaCaching {
    func load(now: Date) -> WeeklyQuotaReading?
    func save(_ reading: WeeklyQuotaReading)
    func clear()
}

final class UserDefaultsWeeklyQuotaCache: WeeklyQuotaCaching {
    private struct Keys {
        let remainingPercent: String
        let resetsAt: String
        let fetchedAt: String
    }

    private static let weeklyKeys = Keys(
        remainingPercent: "usage.weekly.remainingPercent",
        resetsAt: "usage.weekly.resetsAt",
        fetchedAt: "usage.weekly.fetchedAt"
    )
    private static let legacyWeeklyKeys = Keys(
        remainingPercent: "usage.remainingPercent",
        resetsAt: "usage.resetsAt",
        fetchedAt: "usage.fetchedAt"
    )
    private static let obsoleteKeys = [
        "usage.fiveHour.remainingPercent",
        "usage.fiveHour.resetsAt",
        "usage.fiveHour.fetchedAt",
        "usage.preferredQuotaWindow"
    ]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(now: Date = Date()) -> WeeklyQuotaReading? {
        let reading = load(keys: Self.weeklyKeys, now: now)
            ?? load(keys: Self.legacyWeeklyKeys, now: now)

        if let reading {
            saveCanonical(reading)
        }
        clearObsoleteState()
        return reading
    }

    func save(_ reading: WeeklyQuotaReading) {
        clear(keys: Self.weeklyKeys)
        guard reading.resetsAt != nil else { return }
        saveCanonical(reading)
    }

    func clear() {
        clear(keys: Self.weeklyKeys)
        clearObsoleteState()
    }

    private func clearObsoleteState() {
        clear(keys: Self.legacyWeeklyKeys)
        Self.obsoleteKeys.forEach(defaults.removeObject(forKey:))
    }

    private func load(keys: Keys, now: Date) -> WeeklyQuotaReading? {
        guard
            defaults.object(forKey: keys.remainingPercent) != nil,
            let resetsAt = defaults.object(forKey: keys.resetsAt) as? Date,
            let fetchedAt = defaults.object(forKey: keys.fetchedAt) as? Date,
            resetsAt > now
        else {
            clear(keys: keys)
            return nil
        }

        return WeeklyQuotaReading(
            remainingPercent: defaults.integer(forKey: keys.remainingPercent),
            resetsAt: resetsAt,
            fetchedAt: fetchedAt
        )
    }

    private func saveCanonical(_ reading: WeeklyQuotaReading) {
        guard let resetsAt = reading.resetsAt else { return }
        defaults.set(reading.remainingPercent, forKey: Self.weeklyKeys.remainingPercent)
        defaults.set(resetsAt, forKey: Self.weeklyKeys.resetsAt)
        defaults.set(reading.fetchedAt, forKey: Self.weeklyKeys.fetchedAt)
    }

    private func clear(keys: Keys) {
        defaults.removeObject(forKey: keys.remainingPercent)
        defaults.removeObject(forKey: keys.resetsAt)
        defaults.removeObject(forKey: keys.fetchedAt)
    }
}

final class AppPreferences {
    private enum Key {
        static let codexPath = "codex.path"
        static let codexVersion = "codex.version"
        static let appLanguage = "display.language"
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

    var appLanguage: AppLanguage {
        get {
            defaults.string(forKey: Key.appLanguage)
                .flatMap(AppLanguage.init(rawValue:))
                ?? .english
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.appLanguage)
        }
    }

    var attemptedLoginRegistration: Bool {
        get { defaults.bool(forKey: Key.attemptedLoginRegistration) }
        set { defaults.set(newValue, forKey: Key.attemptedLoginRegistration) }
    }
}
