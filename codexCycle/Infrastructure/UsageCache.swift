import Foundation

protocol UsageCaching {
    func load(now: Date) -> QuotaUsageSnapshot?
    func save(_ snapshot: QuotaUsageSnapshot)
    func clear()
}

final class UserDefaultsUsageCache: UsageCaching {
    private enum LegacyKey {
        static let remainingPercent = "usage.remainingPercent"
        static let resetsAt = "usage.resetsAt"
        static let fetchedAt = "usage.fetchedAt"
    }

    private let defaults: UserDefaults

    private struct WindowKeys {
        let remainingPercent: String
        let resetsAt: String
        let fetchedAt: String
    }

    private static let legacyKeys = WindowKeys(
        remainingPercent: LegacyKey.remainingPercent,
        resetsAt: LegacyKey.resetsAt,
        fetchedAt: LegacyKey.fetchedAt
    )

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(now: Date = Date()) -> QuotaUsageSnapshot? {
        let weekly = load(window: .weekly, now: now)
            ?? loadLegacyWeekly(now: now)
        let snapshot = QuotaUsageSnapshot(
            fiveHour: load(window: .fiveHour, now: now),
            weekly: weekly
        )
        return snapshot.isEmpty ? nil : snapshot
    }

    func save(_ snapshot: QuotaUsageSnapshot) {
        clear()
        save(snapshot.fiveHour, window: .fiveHour)
        save(snapshot.weekly, window: .weekly)
    }

    func clear() {
        QuotaWindow.allCases.forEach(clear(window:))
        clearLegacy()
    }

    private func load(
        window: QuotaWindow,
        now: Date
    ) -> QuotaUsageReading? {
        load(keys: keys(for: window), now: now)
    }

    private func loadLegacyWeekly(now: Date) -> QuotaUsageReading? {
        load(keys: Self.legacyKeys, now: now)
    }

    private func load(
        keys: WindowKeys,
        now: Date
    ) -> QuotaUsageReading? {
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

    private func save(
        _ reading: QuotaUsageReading?,
        window: QuotaWindow
    ) {
        guard let reading, let resetsAt = reading.resetsAt else {
            return
        }

        let key = keys(for: window)
        defaults.set(reading.remainingPercent, forKey: key.remainingPercent)
        defaults.set(resetsAt, forKey: key.resetsAt)
        defaults.set(reading.fetchedAt, forKey: key.fetchedAt)
    }

    private func clearLegacy() {
        clear(keys: Self.legacyKeys)
    }

    private func clear(window: QuotaWindow) {
        clear(keys: keys(for: window))
    }

    private func clear(keys: WindowKeys) {
        defaults.removeObject(forKey: keys.remainingPercent)
        defaults.removeObject(forKey: keys.resetsAt)
        defaults.removeObject(forKey: keys.fetchedAt)
    }

    private func keys(for window: QuotaWindow) -> WindowKeys {
        let prefix = "usage.\(window.rawValue)"
        return WindowKeys(
            remainingPercent: "\(prefix).remainingPercent",
            resetsAt: "\(prefix).resetsAt",
            fetchedAt: "\(prefix).fetchedAt"
        )
    }
}

final class AppPreferences {
    private enum Key {
        static let codexPath = "codex.path"
        static let codexVersion = "codex.version"
        static let preferredQuotaWindow = "usage.preferredQuotaWindow"
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

    var preferredQuotaWindow: QuotaWindow {
        get {
            defaults.string(forKey: Key.preferredQuotaWindow)
                .flatMap(QuotaWindow.init(rawValue:))
                ?? .fiveHour
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.preferredQuotaWindow)
        }
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
