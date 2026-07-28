import XCTest
@testable import codexCycle

final class RelativeTimeFormatterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCountdownUsesAtMostTwoUnits() {
        XCTAssertEqual(
            RelativeTimeText.countdown(to: now.addingTimeInterval(2 * 86_400 + 3 * 3_600), now: now),
            "2 天 3 小时"
        )
        XCTAssertEqual(
            RelativeTimeText.countdown(to: now.addingTimeInterval(4 * 3_600 + 18 * 60), now: now),
            "4 小时 18 分钟"
        )
        XCTAssertEqual(
            RelativeTimeText.countdown(to: now.addingTimeInterval(42), now: now),
            "不足 1 分钟"
        )
        XCTAssertEqual(RelativeTimeText.countdown(to: nil, now: now), "—")
    }

    func testLastUpdatedUsesChineseRelativeText() {
        XCTAssertEqual(RelativeTimeText.since(now.addingTimeInterval(-10), now: now), "刚刚")
        XCTAssertEqual(RelativeTimeText.since(now.addingTimeInterval(-180), now: now), "3 分钟前")
        XCTAssertEqual(RelativeTimeText.since(now.addingTimeInterval(-7_200), now: now), "2 小时前")
        XCTAssertEqual(RelativeTimeText.since(now.addingTimeInterval(-172_800), now: now), "2 天前")
    }
}
