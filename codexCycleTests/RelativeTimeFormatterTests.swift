import XCTest
@testable import codexCycle

final class RelativeTimeFormatterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCountdownUsesAtMostTwoUnits() {
        XCTAssertEqual(
            RelativeTimeText.countdown(to: now.addingTimeInterval(2 * 86_400 + 3 * 3_600), now: now),
            "2 days 3 hours"
        )
        XCTAssertEqual(
            RelativeTimeText.countdown(to: now.addingTimeInterval(4 * 3_600 + 18 * 60), now: now),
            "4 hours 18 minutes"
        )
        XCTAssertEqual(
            RelativeTimeText.countdown(to: now.addingTimeInterval(42), now: now),
            "less than 1 minute"
        )
        XCTAssertEqual(RelativeTimeText.countdown(to: nil, now: now), "—")
    }

    func testLastUpdatedUsesEnglishByDefault() {
        XCTAssertEqual(RelativeTimeText.since(now.addingTimeInterval(-10), now: now), "just now")
        XCTAssertEqual(RelativeTimeText.since(now.addingTimeInterval(-180), now: now), "3 minutes ago")
        XCTAssertEqual(RelativeTimeText.since(now.addingTimeInterval(-7_200), now: now), "2 hours ago")
        XCTAssertEqual(RelativeTimeText.since(now.addingTimeInterval(-172_800), now: now), "2 days ago")
    }

    func testChineseRelativeTextRemainsAvailable() {
        let localization = AppLocalization(language: .simplifiedChinese)

        XCTAssertEqual(
            RelativeTimeText.countdown(
                to: now.addingTimeInterval(2 * 86_400 + 3 * 3_600),
                now: now,
                localization: localization
            ),
            "2 天 3 小时"
        )
        XCTAssertEqual(
            RelativeTimeText.since(
                now.addingTimeInterval(-180),
                now: now,
                localization: localization
            ),
            "3 分钟前"
        )
    }
}
