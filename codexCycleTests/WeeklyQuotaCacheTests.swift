import XCTest
@testable import codexCycle

final class WeeklyQuotaCacheTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var cache: UserDefaultsWeeklyQuotaCache!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "codexCycleTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        cache = UserDefaultsWeeklyQuotaCache(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        cache = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testPersistsReadingWithFutureResetAsStaleStartupData() {
        let reading = WeeklyQuotaReading(
            remainingPercent: 44,
            resetsAt: now.addingTimeInterval(3_600),
            fetchedAt: now.addingTimeInterval(-300)
        )

        cache.save(reading)

        XCTAssertEqual(cache.load(now: now), reading)
    }

    func testDiscardsReadingAfterReset() {
        cache.save(
            WeeklyQuotaReading(
                remainingPercent: 44,
                resetsAt: now.addingTimeInterval(-1),
                fetchedAt: now.addingTimeInterval(-300)
            )
        )

        XCTAssertNil(cache.load(now: now))
    }

    func testDoesNotPersistReadingWithoutResetTimestamp() {
        cache.save(
            WeeklyQuotaReading(
                remainingPercent: 44,
                resetsAt: nil,
                fetchedAt: now
            )
        )

        XCTAssertNil(cache.load(now: now))
    }

    func testPreservesWeeklyCacheAndClearsObsoleteQuotaKeys() {
        let reset = now.addingTimeInterval(86_400)
        defaults.set(42, forKey: "usage.weekly.remainingPercent")
        defaults.set(reset, forKey: "usage.weekly.resetsAt")
        defaults.set(now, forKey: "usage.weekly.fetchedAt")
        defaults.set(75, forKey: "usage.fiveHour.remainingPercent")
        defaults.set(reset, forKey: "usage.fiveHour.resetsAt")
        defaults.set(now, forKey: "usage.fiveHour.fetchedAt")
        defaults.set("fiveHour", forKey: "usage.preferredQuotaWindow")

        XCTAssertEqual(
            cache.load(now: now),
            WeeklyQuotaReading(
                remainingPercent: 42,
                resetsAt: reset,
                fetchedAt: now
            )
        )
        XCTAssertNil(defaults.object(forKey: "usage.fiveHour.remainingPercent"))
        XCTAssertNil(defaults.object(forKey: "usage.fiveHour.resetsAt"))
        XCTAssertNil(defaults.object(forKey: "usage.fiveHour.fetchedAt"))
        XCTAssertNil(defaults.object(forKey: "usage.preferredQuotaWindow"))
    }

    func testMigratesValidLegacyWeeklyCache() {
        let reset = now.addingTimeInterval(86_400)
        defaults.set(42, forKey: "usage.remainingPercent")
        defaults.set(reset, forKey: "usage.resetsAt")
        defaults.set(now, forKey: "usage.fetchedAt")

        let reading = cache.load(now: now)

        XCTAssertEqual(
            reading,
            WeeklyQuotaReading(
                remainingPercent: 42,
                resetsAt: reset,
                fetchedAt: now
            )
        )
        XCTAssertEqual(defaults.integer(forKey: "usage.weekly.remainingPercent"), 42)
        XCTAssertEqual(defaults.object(forKey: "usage.weekly.resetsAt") as? Date, reset)
        XCTAssertNil(defaults.object(forKey: "usage.remainingPercent"))
        XCTAssertNil(defaults.object(forKey: "usage.resetsAt"))
        XCTAssertNil(defaults.object(forKey: "usage.fetchedAt"))
    }
}

final class AppPreferencesTests: XCTestCase {
    func testLanguageDefaultsToEnglishAndPersistsSelection() throws {
        let suiteName = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)

        XCTAssertEqual(preferences.appLanguage, .english)

        preferences.appLanguage = .simplifiedChinese

        XCTAssertEqual(
            AppPreferences(defaults: defaults).appLanguage,
            .simplifiedChinese
        )
    }
}
