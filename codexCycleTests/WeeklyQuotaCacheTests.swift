import XCTest
@testable import codexCycle

final class QuotaUsageCacheTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var cache: UserDefaultsQuotaUsageCache!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "codexCycleTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        cache = UserDefaultsQuotaUsageCache(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        cache = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testPersistsBothWindowsWithFutureResets() {
        let snapshot = QuotaUsageSnapshot(
            fiveHour: reading(remaining: 75, resetOffset: 3_600),
            weekly: reading(remaining: 44, resetOffset: 86_400)
        )

        cache.save(snapshot)

        XCTAssertEqual(cache.load(now: now), snapshot)
    }

    func testExpiresEachCachedWindowIndependently() {
        let weekly = reading(remaining: 44, resetOffset: 86_400)
        cache.save(
            QuotaUsageSnapshot(
                fiveHour: reading(remaining: 70, resetOffset: -1),
                weekly: weekly
            )
        )

        XCTAssertEqual(
            cache.load(now: now),
            QuotaUsageSnapshot(fiveHour: nil, weekly: weekly)
        )
    }

    func testDoesNotPersistWindowWithoutResetTimestamp() {
        cache.save(
            QuotaUsageSnapshot(
                fiveHour: QuotaUsageReading(
                    remainingPercent: 44,
                    resetsAt: nil,
                    fetchedAt: now
                ),
                weekly: nil
            )
        )

        XCTAssertNil(cache.load(now: now))
    }

    func testRestoresExistingFiveHourAndWeeklyCacheAndRemovesOldPreference() {
        let fiveHourReset = now.addingTimeInterval(3_600)
        let weeklyReset = now.addingTimeInterval(86_400)
        defaults.set(75, forKey: "usage.fiveHour.remainingPercent")
        defaults.set(fiveHourReset, forKey: "usage.fiveHour.resetsAt")
        defaults.set(now, forKey: "usage.fiveHour.fetchedAt")
        defaults.set(42, forKey: "usage.weekly.remainingPercent")
        defaults.set(weeklyReset, forKey: "usage.weekly.resetsAt")
        defaults.set(now, forKey: "usage.weekly.fetchedAt")
        defaults.set("fiveHour", forKey: "usage.preferredQuotaWindow")

        XCTAssertEqual(
            cache.load(now: now),
            QuotaUsageSnapshot(
                fiveHour: QuotaUsageReading(
                    remainingPercent: 75,
                    resetsAt: fiveHourReset,
                    fetchedAt: now
                ),
                weekly: QuotaUsageReading(
                    remainingPercent: 42,
                    resetsAt: weeklyReset,
                    fetchedAt: now
                )
            )
        )
        XCTAssertNil(defaults.object(forKey: "usage.preferredQuotaWindow"))
    }

    func testMigratesValidLegacyWeeklyCache() {
        let reset = now.addingTimeInterval(86_400)
        defaults.set(42, forKey: "usage.remainingPercent")
        defaults.set(reset, forKey: "usage.resetsAt")
        defaults.set(now, forKey: "usage.fetchedAt")

        XCTAssertEqual(
            cache.load(now: now)?.weekly,
            QuotaUsageReading(
                remainingPercent: 42,
                resetsAt: reset,
                fetchedAt: now
            )
        )
        XCTAssertEqual(defaults.integer(forKey: "usage.weekly.remainingPercent"), 42)
        XCTAssertNil(defaults.object(forKey: "usage.remainingPercent"))
    }

    private func reading(remaining: Int, resetOffset: TimeInterval) -> QuotaUsageReading {
        QuotaUsageReading(
            remainingPercent: remaining,
            resetsAt: now.addingTimeInterval(resetOffset),
            fetchedAt: now.addingTimeInterval(-300)
        )
    }
}

final class AppPreferencesTests: XCTestCase {
    func testRemovesObsoleteExplicitLanguageSelection() throws {
        let suiteName = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("zh-Hans", forKey: "display.language")

        _ = AppPreferences(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "display.language"))
    }

    func testPersistsLastDailyCodexRequestDate() throws {
        let suiteName = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        AppPreferences(defaults: defaults).lastDailyCodexRequestAt = date

        XCTAssertEqual(AppPreferences(defaults: defaults).lastDailyCodexRequestAt, date)
    }
}

final class DailyCodexRequestScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        return calendar
    }

    func testBecomesDueAtSevenAndOnlyOncePerCalendarDay() throws {
        let schedule = DailyCodexRequestSchedule(calendar: calendar)
        let beforeSeven = try date(2026, 8, 25, 6, 59)
        let seven = try date(2026, 8, 25, 7, 0)
        let earlierToday = try date(2026, 8, 25, 7, 1)
        let yesterday = try date(2026, 8, 24, 7, 1)

        XCTAssertFalse(schedule.isDue(now: beforeSeven, lastAttemptAt: yesterday))
        XCTAssertTrue(schedule.isDue(now: seven, lastAttemptAt: yesterday))
        XCTAssertFalse(schedule.isDue(now: seven, lastAttemptAt: earlierToday))
    }

    func testNextFireUsesTodayBeforeSevenAndTomorrowAfterSeven() throws {
        let schedule = DailyCodexRequestSchedule(calendar: calendar)

        XCTAssertEqual(
            schedule.nextFireDate(after: try date(2026, 8, 25, 6, 0)),
            try date(2026, 8, 25, 7, 0)
        )
        XCTAssertEqual(
            schedule.nextFireDate(after: try date(2026, 8, 25, 7, 0)),
            try date(2026, 8, 26, 7, 0)
        )
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
    }
}
