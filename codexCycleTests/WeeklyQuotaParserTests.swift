import XCTest
@testable import codexCycle

final class WeeklyQuotaParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testReadsWeeklyWindowAndIgnoresFiveHourWindow() throws {
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

        let reading = try WeeklyQuotaParser.parse(response, fetchedAt: now)

        XCTAssertEqual(reading.remainingPercent, 40)
        XCTAssertEqual(
            reading.resetsAt,
            Date(timeIntervalSince1970: 1_800_100_000)
        )
        XCTAssertEqual(reading.fetchedAt, now)
    }

    func testReadsWeeklyWindowFromPrimary() throws {
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

        XCTAssertEqual(
            try WeeklyQuotaParser.parse(response, fetchedAt: now).remainingPercent,
            60
        )
    }

    func testUsesOnlyMainCodexBucket() throws {
        let response = GetAccountRateLimitsResult(
            rateLimits: snapshot(id: "codex", used: 99, duration: 300),
            rateLimitsByLimitId: [
                "codex_other": snapshot(id: "codex_other", used: 90, duration: 10_080),
                "codex": snapshot(
                    id: "codex",
                    used: 3,
                    duration: 10_080,
                    reset: 1_800_100_000
                )
            ]
        )

        let reading = try WeeklyQuotaParser.parse(response, fetchedAt: now)

        XCTAssertEqual(reading.remainingPercent, 97)
        XCTAssertEqual(
            reading.resetsAt,
            Date(timeIntervalSince1970: 1_800_100_000)
        )
    }

    func testRejectsFiveHourOnlyResponse() {
        let response = GetAccountRateLimitsResult(
            rateLimits: snapshot(id: "codex", used: 12, duration: 300),
            rateLimitsByLimitId: nil
        )

        XCTAssertThrowsError(try WeeklyQuotaParser.parse(response, fetchedAt: now)) {
            XCTAssertEqual($0 as? WeeklyQuotaError, .weeklyWindowUnavailable)
        }
    }

    func testRejectsNonCodexBucket() {
        let response = GetAccountRateLimitsResult(
            rateLimits: snapshot(id: "codex_other", used: 12, duration: 10_080),
            rateLimitsByLimitId: nil
        )

        XCTAssertThrowsError(try WeeklyQuotaParser.parse(response, fetchedAt: now)) {
            XCTAssertEqual($0 as? WeeklyQuotaError, .noMainCodexBucket)
        }
    }

    func testFloorsAndClampsRemainingPercentage() throws {
        let fractional = GetAccountRateLimitsResult(
            rateLimits: snapshot(id: "codex", used: 80.1, duration: 10_080),
            rateLimitsByLimitId: nil
        )
        let overused = GetAccountRateLimitsResult(
            rateLimits: snapshot(id: "codex", used: 104, duration: 10_080),
            rateLimitsByLimitId: nil
        )

        XCTAssertEqual(
            try WeeklyQuotaParser.parse(fractional, fetchedAt: now).remainingPercent,
            19
        )
        XCTAssertEqual(
            try WeeklyQuotaParser.parse(overused, fetchedAt: now).remainingPercent,
            0
        )
    }

    func testAcceptsReadingWithoutResetTimestamp() throws {
        let response = GetAccountRateLimitsResult(
            rateLimits: snapshot(id: "codex", used: 25, duration: 10_080),
            rateLimitsByLimitId: nil
        )

        let reading = try WeeklyQuotaParser.parse(response, fetchedAt: now)

        XCTAssertEqual(reading.remainingPercent, 75)
        XCTAssertNil(reading.resetsAt)
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
