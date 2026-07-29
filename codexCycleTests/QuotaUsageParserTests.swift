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
                "codex": snapshot(id: "codex", used: 3, duration: 10_080, reset: 1_800_100_000)
            ]
        )

        let result = try QuotaUsageParser.parse(response, fetchedAt: now)

        XCTAssertNil(result.fiveHour)
        XCTAssertEqual(result.weekly?.remainingPercent, 97)
        XCTAssertEqual(
            result.weekly?.resetsAt,
            Date(timeIntervalSince1970: 1_800_100_000)
        )
        XCTAssertEqual(result.weekly?.fetchedAt, now)
    }

    func testRejectsUnsupportedWindowInsteadOfSubstitutingIt() {
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
            rateLimits: snapshot(id: "codex", used: 104, duration: 10_080),
            rateLimitsByLimitId: nil
        )

        XCTAssertEqual(
            try QuotaUsageParser.parse(fractional, fetchedAt: now)
                .weekly?.remainingPercent,
            19
        )
        XCTAssertEqual(
            try QuotaUsageParser.parse(overused, fetchedAt: now)
                .weekly?.remainingPercent,
            0
        )
    }

    func testAcceptsReadingWithoutResetTimestamp() throws {
        let response = GetAccountRateLimitsResult(
            rateLimits: snapshot(id: "codex", used: 25, duration: 10_080),
            rateLimitsByLimitId: nil
        )

        let reading = try QuotaUsageParser.parse(response, fetchedAt: now).weekly

        XCTAssertEqual(reading?.remainingPercent, 75)
        XCTAssertNil(reading?.resetsAt)
    }

    func testUsageLevelsUseConfirmedThresholds() {
        XCTAssertEqual(UsageLevel(remainingPercent: 50), .sufficient)
        XCTAssertEqual(UsageLevel(remainingPercent: 49), .low)
        XCTAssertEqual(UsageLevel(remainingPercent: 20), .low)
        XCTAssertEqual(UsageLevel(remainingPercent: 19), .critical)
    }

    func testGradientUsesRedYellowGreenAnchors() {
        XCTAssertEqual(UsageGradient.color(at: 0), UsageGradient.red)
        XCTAssertEqual(UsageGradient.color(at: 20), UsageGradient.yellow)
        XCTAssertEqual(UsageGradient.color(at: 50), UsageGradient.green)
        XCTAssertEqual(UsageGradient.color(at: 100), UsageGradient.green)
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

final class QuotaDisplaySelectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testUnavailablePreferredWindowFallsBackWithoutChangingPreference() {
        let weekly = QuotaUsageReading(
            remainingPercent: 42,
            resetsAt: now.addingTimeInterval(86_400),
            fetchedAt: now
        )
        let snapshot = QuotaUsageSnapshot(fiveHour: nil, weekly: weekly)

        let selection = QuotaDisplaySelection(
            preferredWindow: .fiveHour,
            snapshot: snapshot
        )

        XCTAssertEqual(selection.preferredWindow, .fiveHour)
        XCTAssertEqual(selection.currentWindow, .weekly)
        XCTAssertEqual(selection.currentReading, weekly)
        XCTAssertTrue(selection.isFallback)
    }

    func testWeeklyPreferenceFallsBackToFiveHourSymmetrically() {
        let fiveHour = QuotaUsageReading(
            remainingPercent: 75,
            resetsAt: now.addingTimeInterval(3_600),
            fetchedAt: now
        )
        let selection = QuotaDisplaySelection(
            preferredWindow: .weekly,
            snapshot: QuotaUsageSnapshot(fiveHour: fiveHour, weekly: nil)
        )

        XCTAssertEqual(selection.preferredWindow, .weekly)
        XCTAssertEqual(selection.currentWindow, .fiveHour)
        XCTAssertEqual(selection.currentReading, fiveHour)
        XCTAssertTrue(selection.isFallback)
    }

    func testHiddenWindowStillContributesItsExpirationBoundary() {
        let hiddenReset = now.addingTimeInterval(300)
        let snapshot = QuotaUsageSnapshot(
            fiveHour: QuotaUsageReading(
                remainingPercent: 75,
                resetsAt: hiddenReset,
                fetchedAt: now
            ),
            weekly: QuotaUsageReading(
                remainingPercent: 42,
                resetsAt: now.addingTimeInterval(86_400),
                fetchedAt: now
            )
        )

        XCTAssertEqual(snapshot.earliestResetAt, hiddenReset)
        XCTAssertEqual(
            QuotaDisplaySelection(
                preferredWindow: .weekly,
                snapshot: snapshot
            ).currentWindow,
            .weekly
        )
    }
}
