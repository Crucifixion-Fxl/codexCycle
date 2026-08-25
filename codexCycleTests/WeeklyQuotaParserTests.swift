import XCTest
@testable import codexCycle

final class QuotaUsageParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testReadsExactFiveHourAndWeeklyWindowsFromMainCodexBucket() throws {
        let response = GetAccountRateLimitsResult(
            rateLimits: RateLimitSnapshot(
                limitId: "codex",
                primary: RateLimitWindow(
                    usedPercent: 25,
                    windowDurationMins: 300,
                    resetsAt: 1_800_010_000
                ),
                secondary: RateLimitWindow(
                    usedPercent: 60,
                    windowDurationMins: 10_080,
                    resetsAt: 1_800_100_000
                )
            ),
            rateLimitsByLimitId: nil
        )

        let snapshot = try QuotaUsageParser.parse(response, fetchedAt: now)

        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 75)
        XCTAssertEqual(
            snapshot.fiveHour?.resetsAt,
            Date(timeIntervalSince1970: 1_800_010_000)
        )
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 40)
        XCTAssertEqual(
            snapshot.weekly?.resetsAt,
            Date(timeIntervalSince1970: 1_800_100_000)
        )
    }

    func testReadsFiveHourFromSecondaryAndWeeklyFromPrimary() throws {
        let response = GetAccountRateLimitsResult(
            rateLimits: RateLimitSnapshot(
                limitId: "codex",
                primary: RateLimitWindow(
                    usedPercent: 40,
                    windowDurationMins: 10_080,
                    resetsAt: nil
                ),
                secondary: RateLimitWindow(
                    usedPercent: 10,
                    windowDurationMins: 300,
                    resetsAt: nil
                )
            ),
            rateLimitsByLimitId: nil
        )

        let snapshot = try QuotaUsageParser.parse(response, fetchedAt: now)

        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 90)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 60)
    }

    func testUsesOnlyMainCodexBucketAndAcceptsPartialAvailability() throws {
        let response = GetAccountRateLimitsResult(
            rateLimits: snapshot(id: "codex", used: 99, duration: 300),
            rateLimitsByLimitId: [
                "codex_other": snapshot(id: "codex_other", used: 90, duration: 10_080),
                "codex": snapshot(id: "codex", used: 3, duration: 10_080)
            ]
        )

        let result = try QuotaUsageParser.parse(response, fetchedAt: now)

        XCTAssertNil(result.fiveHour)
        XCTAssertEqual(result.weekly?.remainingPercent, 97)
        XCTAssertEqual(result.weekly?.fetchedAt, now)
    }

    func testAcceptsFiveHourOnlyResponse() throws {
        let response = GetAccountRateLimitsResult(
            rateLimits: snapshot(id: "codex", used: 12, duration: 300),
            rateLimitsByLimitId: nil
        )

        let snapshot = try QuotaUsageParser.parse(response, fetchedAt: now)

        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 88)
        XCTAssertNil(snapshot.weekly)
    }

    func testRejectsUnsupportedWindow() {
        let response = GetAccountRateLimitsResult(
            rateLimits: snapshot(id: "codex", used: 12, duration: 60),
            rateLimitsByLimitId: nil
        )

        XCTAssertThrowsError(try QuotaUsageParser.parse(response, fetchedAt: now)) {
            XCTAssertEqual($0 as? QuotaUsageError, .noSupportedWindows)
        }
    }

    func testRejectsNonCodexBucket() {
        let response = GetAccountRateLimitsResult(
            rateLimits: snapshot(id: "codex_other", used: 12, duration: 10_080),
            rateLimitsByLimitId: nil
        )

        XCTAssertThrowsError(try QuotaUsageParser.parse(response, fetchedAt: now)) {
            XCTAssertEqual($0 as? QuotaUsageError, .noMainCodexBucket)
        }
    }

    func testFloorsAndClampsRemainingPercentage() throws {
        let fractional = GetAccountRateLimitsResult(
            rateLimits: snapshot(id: "codex", used: 80.1, duration: 10_080),
            rateLimitsByLimitId: nil
        )
        let overused = GetAccountRateLimitsResult(
            rateLimits: snapshot(id: "codex", used: 104, duration: 300),
            rateLimitsByLimitId: nil
        )

        XCTAssertEqual(
            try QuotaUsageParser.parse(fractional, fetchedAt: now)
                .weekly?.remainingPercent,
            19
        )
        XCTAssertEqual(
            try QuotaUsageParser.parse(overused, fetchedAt: now)
                .fiveHour?.remainingPercent,
            0
        )
    }

    func testExpiresWindowsIndependently() {
        let weekly = QuotaUsageReading(
            remainingPercent: 42,
            resetsAt: now.addingTimeInterval(86_400),
            fetchedAt: now
        )
        let snapshot = QuotaUsageSnapshot(
            fiveHour: QuotaUsageReading(
                remainingPercent: 75,
                resetsAt: now.addingTimeInterval(-1),
                fetchedAt: now
            ),
            weekly: weekly
        )

        XCTAssertEqual(
            snapshot.removingExpiredReadings(at: now),
            QuotaUsageSnapshot(fiveHour: nil, weekly: weekly)
        )
    }

    private func snapshot(
        id: String,
        used: Double,
        duration: Int64,
        reset: Int64? = nil
    ) -> RateLimitSnapshot {
        RateLimitSnapshot(
            limitId: id,
            primary: RateLimitWindow(
                usedPercent: used,
                windowDurationMins: duration,
                resetsAt: reset
            ),
            secondary: nil
        )
    }
}
