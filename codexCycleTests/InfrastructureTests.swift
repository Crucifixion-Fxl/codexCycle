import XCTest
@testable import codexCycle

final class InfrastructureTests: XCTestCase {
    func testCodexVersionParsingAndOrdering() throws {
        let stable = try XCTUnwrap(
            SemanticVersion.parseCodexVersion(
                from: "warning line\ncodex-cli 0.145.0\n"
            )
        )
        let newer = try XCTUnwrap(
            SemanticVersion.parseCodexVersion(from: "codex-cli 0.146.0")
        )
        let prerelease = try XCTUnwrap(
            SemanticVersion.parseCodexVersion(from: "codex-cli 0.146.0-beta.1")
        )

        XCTAssertEqual(stable.description, "0.145.0")
        XCTAssertGreaterThan(newer, stable)
        XCTAssertLessThan(prerelease, newer)
    }

    func testStableErrorClassification() {
        XCTAssertEqual(DisplayErrorReason.classify(CodexLocatorError.notFound), .cliNotFound)
        XCTAssertEqual(DisplayErrorReason.classify(CodexLocatorError.incompatible), .incompatibleCLI)
        XCTAssertEqual(DisplayErrorReason.classify(WeeklyUsageError.noWeeklyWindow), .weeklyLimitMissing)
        XCTAssertEqual(
            DisplayErrorReason.classify(
                AppServerClientError.server(code: 401, message: "authentication required")
            ),
            .notLoggedIn
        )
        XCTAssertEqual(DisplayErrorReason.classify(AppServerClientError.timedOut), .networkFailure)
    }

    func testStatusIndicatorFillsAvailableHeightAndUsesLargerDigits() {
        let minimumDimension: CGFloat = 22
        let outerRadius = StatusIndicatorMetrics.ringRadius(
            for: minimumDimension
        ) + StatusIndicatorMetrics.ringLineWidth / 2

        XCTAssertEqual(outerRadius, minimumDimension / 2, accuracy: 0.001)
        XCTAssertEqual(
            StatusIndicatorMetrics.fontSize(forCharacterCount: 1),
            11,
            accuracy: 0.001
        )
        XCTAssertEqual(
            StatusIndicatorMetrics.fontSize(forCharacterCount: 2),
            10,
            accuracy: 0.001
        )
        XCTAssertEqual(
            StatusIndicatorMetrics.fontSize(forCharacterCount: 3),
            8.6,
            accuracy: 0.001
        )
    }
}
