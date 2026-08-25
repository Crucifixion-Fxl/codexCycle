import Foundation

protocol QuotaUsageCaching {
    func load(now: Date) -> QuotaUsageSnapshot?
    func save(_ snapshot: QuotaUsageSnapshot)
    func clear()
}

final class UserDefaultsQuotaUsageCache: QuotaUsageCaching {
    private struct Keys {
        let remainingPercent: String
        let resetsAt: String
        let fetchedAt: String
    }

    private static let fiveHourKeys = Keys(
        remainingPercent: "usage.fiveHour.remainingPercent",
        resetsAt: "usage.fiveHour.resetsAt",
        fetchedAt: "usage.fiveHour.fetchedAt"
    )
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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(now: Date = Date()) -> QuotaUsageSnapshot? {
        let weekly = load(keys: Self.weeklyKeys, now: now)
            ?? load(keys: Self.legacyWeeklyKeys, now: now)
        let snapshot = QuotaUsageSnapshot(
            fiveHour: load(keys: Self.fiveHourKeys, now: now),
            weekly: weekly
        )

        if let weekly {
            save(weekly, keys: Self.weeklyKeys)
        }
        clear(keys: Self.legacyWeeklyKeys)
        defaults.removeObject(forKey: "usage.preferredQuotaWindow")
        return snapshot.isEmpty ? nil : snapshot
    }

    func save(_ snapshot: QuotaUsageSnapshot) {
        clear()
        if let fiveHour = snapshot.fiveHour {
            save(fiveHour, keys: Self.fiveHourKeys)
        }
        if let weekly = snapshot.weekly {
            save(weekly, keys: Self.weeklyKeys)
        }
    }

    func clear() {
        clear(keys: Self.fiveHourKeys)
        clear(keys: Self.weeklyKeys)
        clear(keys: Self.legacyWeeklyKeys)
        defaults.removeObject(forKey: "usage.preferredQuotaWindow")
    }

    private func load(keys: Keys, now: Date) -> QuotaUsageReading? {
        guard
            defaults.object(forKey: keys.remainingPercent) != nil,
            let resetsAt = defaults.object(forKey: keys.resetsAt) as? Date,
            let fetchedAt = defaults.object(forKey: keys.fetchedAt) as? Date,
            resetsAt > now
        else {
            clear(keys: keys)
            return nil
        }

        return QuotaUsageReading(
            remainingPercent: defaults.integer(forKey: keys.remainingPercent),
            resetsAt: resetsAt,
            fetchedAt: fetchedAt
        )
    }

    private func save(_ reading: QuotaUsageReading, keys: Keys) {
        guard let resetsAt = reading.resetsAt else { return }
        defaults.set(reading.remainingPercent, forKey: keys.remainingPercent)
        defaults.set(resetsAt, forKey: keys.resetsAt)
        defaults.set(reading.fetchedAt, forKey: keys.fetchedAt)
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
        static let obsoleteAppLanguage = "display.language"
        static let attemptedLoginRegistration = "launchAtLogin.registrationAttempted"
        static let lastDailyCodexRequestAt = "dailyCodexRequest.lastAttemptAt"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.removeObject(forKey: Key.obsoleteAppLanguage)
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

    var lastDailyCodexRequestAt: Date? {
        get { defaults.object(forKey: Key.lastDailyCodexRequestAt) as? Date }
        set { defaults.set(newValue, forKey: Key.lastDailyCodexRequestAt) }
    }
}
