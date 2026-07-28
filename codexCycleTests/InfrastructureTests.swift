import AppKit
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

    func testStatusIndicatorUsesExpandedCapsuleAndLargerDigits() {
        let bounds = NSRect(
            x: 0,
            y: 0,
            width: StatusIndicatorMetrics.statusItemWidth,
            height: 22
        )
        let ringRect = StatusIndicatorMetrics.ringRect(in: bounds)

        XCTAssertEqual(
            ringRect.width + StatusIndicatorMetrics.ringLineWidth,
            StatusIndicatorMetrics.statusItemWidth,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ringRect.height + StatusIndicatorMetrics.ringLineWidth,
            bounds.height,
            accuracy: 0.001
        )
        XCTAssertEqual(
            StatusIndicatorMetrics.fontSize(forCharacterCount: 1),
            13,
            accuracy: 0.001
        )
        XCTAssertEqual(
            StatusIndicatorMetrics.fontSize(forCharacterCount: 2),
            12,
            accuracy: 0.001
        )
        XCTAssertEqual(
            StatusIndicatorMetrics.fontSize(forCharacterCount: 3),
            10.6,
            accuracy: 0.001
        )
    }

    func testCapsuleProgressPathClosesAtTopCenter() {
        let bounds = NSRect(x: 0, y: 0, width: 34, height: 22)
        let geometry = CapsuleRingGeometry(
            rect: StatusIndicatorMetrics.ringRect(in: bounds)
        )

        let start = geometry.point(at: 0)
        let halfway = geometry.point(at: 0.5)
        let end = geometry.point(at: 1)

        XCTAssertEqual(start.x, bounds.midX, accuracy: 0.001)
        XCTAssertEqual(start.y, geometry.rect.maxY, accuracy: 0.001)
        XCTAssertEqual(halfway.x, bounds.midX, accuracy: 0.001)
        XCTAssertEqual(halfway.y, geometry.rect.minY, accuracy: 0.001)
        XCTAssertEqual(end.x, start.x, accuracy: 0.001)
        XCTAssertEqual(end.y, start.y, accuracy: 0.001)
    }

    @MainActor
    func testStatusIndicatorRendersExpandedCapsule() throws {
        let view = StatusIndicatorView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: StatusIndicatorMetrics.statusItemWidth,
                height: 22
            )
        )
        view.remainingPercent = 96
        view.isStale = false
        view.layoutSubtreeIfNeeded()

        let representation = try XCTUnwrap(
            view.bitmapImageRepForCachingDisplay(in: view.bounds)
        )
        view.cacheDisplay(in: view.bounds, to: representation)
        let pngData = try XCTUnwrap(
            representation.representation(using: .png, properties: [:])
        )

        XCTAssertGreaterThan(pngData.count, 0)
        let attachment = XCTAttachment(
            data: pngData,
            uniformTypeIdentifier: "public.png"
        )
        attachment.name = "Expanded quota indicator"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
