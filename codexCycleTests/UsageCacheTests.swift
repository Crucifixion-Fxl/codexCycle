import XCTest
@testable import codexCycle

final class UsageCacheTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var cache: UserDefaultsUsageCache!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "codexCycleTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        cache = UserDefaultsUsageCache(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        cache = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testPersistsSnapshotWithFutureResetAsStaleStartupData() {
        let reading = QuotaUsageReading(
            remainingPercent: 44,
            resetsAt: now.addingTimeInterval(3_600),
            fetchedAt: now.addingTimeInterval(-300)
        )
        let snapshot = QuotaUsageSnapshot(fiveHour: reading, weekly: nil)

        cache.save(snapshot)

        XCTAssertEqual(cache.load(now: now), snapshot)
    }

    func testExpiresEachCachedWindowIndependently() {
        let weekly = QuotaUsageReading(
            remainingPercent: 44,
            resetsAt: now.addingTimeInterval(86_400),
            fetchedAt: now.addingTimeInterval(-300)
        )
        cache.save(
            QuotaUsageSnapshot(
                fiveHour: QuotaUsageReading(
                    remainingPercent: 70,
                    resetsAt: now.addingTimeInterval(-1),
                    fetchedAt: now.addingTimeInterval(-300)
                ),
                weekly: weekly
            )
        )

        XCTAssertEqual(
            cache.load(now: now),
            QuotaUsageSnapshot(fiveHour: nil, weekly: weekly)
        )
    }

    func testDiscardsSnapshotAfterItsOnlyWindowResets() {
        cache.save(
            QuotaUsageSnapshot(
                fiveHour: nil,
                weekly: QuotaUsageReading(
                    remainingPercent: 44,
                    resetsAt: now.addingTimeInterval(-1),
                    fetchedAt: now.addingTimeInterval(-300)
                )
            )
        )

        XCTAssertNil(cache.load(now: now))
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

    func testPreferredQuotaWindowDefaultsToFiveHourAndPersistsSelection() {
        let preferences = AppPreferences(defaults: defaults)

        XCTAssertEqual(preferences.preferredQuotaWindow, .fiveHour)

        preferences.preferredQuotaWindow = .weekly

        XCTAssertEqual(
            AppPreferences(defaults: defaults).preferredQuotaWindow,
            .weekly
        )
    }
}
