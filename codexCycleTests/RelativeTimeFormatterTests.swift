import XCTest
@testable import codexCycle

final class RelativeTimeFormatterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCountdownUsesAtMostTwoUnits() throws {
        let localization = try localization(for: "en")

        XCTAssertEqual(
            RelativeTimeText.countdown(
                to: now.addingTimeInterval(2 * 86_400 + 3 * 3_600),
                now: now,
                localization: localization
            ),
            "2 days 3 hours"
        )
        XCTAssertEqual(
            RelativeTimeText.countdown(
                to: now.addingTimeInterval(4 * 3_600 + 18 * 60),
                now: now,
                localization: localization
            ),
            "4 hours 18 minutes"
        )
        XCTAssertEqual(
            RelativeTimeText.countdown(
                to: now.addingTimeInterval(42),
                now: now,
                localization: localization
            ),
            "less than 1 minute"
        )
        XCTAssertEqual(
            RelativeTimeText.countdown(to: nil, now: now, localization: localization),
            "—"
        )
    }

    func testLastUpdatedUsesEnglishLocalization() throws {
        let localization = try localization(for: "en")

        XCTAssertEqual(
            RelativeTimeText.since(
                now.addingTimeInterval(-10),
                now: now,
                localization: localization
            ),
            "just now"
        )
        XCTAssertEqual(
            RelativeTimeText.since(
                now.addingTimeInterval(-180),
                now: now,
                localization: localization
            ),
            "3 minutes ago"
        )
        XCTAssertEqual(
            RelativeTimeText.since(
                now.addingTimeInterval(-7_200),
                now: now,
                localization: localization
            ),
            "2 hours ago"
        )
        XCTAssertEqual(
            RelativeTimeText.since(
                now.addingTimeInterval(-172_800),
                now: now,
                localization: localization
            ),
            "2 days ago"
        )
    }

    func testChineseRelativeTextRemainsAvailable() throws {
        let localization = try localization(for: "zh-Hans")

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

    func testDefaultLocalizationUsesTheSystemSelectedMainBundle() {
        XCTAssertEqual(
            AppLocalization().text("menu.refresh"),
            Bundle.main.localizedString(
                forKey: "menu.refresh",
                value: "menu.refresh",
                table: nil
            )
        )
    }

    private func localization(for identifier: String) throws -> AppLocalization {
        let path = try XCTUnwrap(
            Bundle.main.path(forResource: identifier, ofType: "lproj")
        )
        let bundle = try XCTUnwrap(Bundle(path: path))
        return AppLocalization(
            bundle: bundle,
            locale: Locale(identifier: identifier)
        )
    }
}
