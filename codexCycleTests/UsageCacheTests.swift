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

    func testPersistsReadingWithFutureResetAsStaleStartupData() {
        let reading = WeeklyUsageReading(
            remainingPercent: 44,
            resetsAt: now.addingTimeInterval(3_600),
            fetchedAt: now.addingTimeInterval(-300)
        )

        cache.save(reading)

        XCTAssertEqual(cache.load(now: now), reading)
    }

    func testDiscardsReadingAfterItsResetWindow() {
        cache.save(
            WeeklyUsageReading(
                remainingPercent: 44,
                resetsAt: now.addingTimeInterval(-1),
                fetchedAt: now.addingTimeInterval(-300)
            )
        )

        XCTAssertNil(cache.load(now: now))
    }

    func testDoesNotPersistReadingWithoutResetTimestamp() {
        cache.save(
            WeeklyUsageReading(
                remainingPercent: 44,
                resetsAt: nil,
                fetchedAt: now
            )
        )

        XCTAssertNil(cache.load(now: now))
    }
}
