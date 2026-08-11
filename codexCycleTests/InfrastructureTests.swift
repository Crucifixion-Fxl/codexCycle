import AppKit
import XCTest
@testable import codexCycle

final class InfrastructureTests: XCTestCase {
    func testDiscoversCurrentDesktopRuntimeWithoutIndependentCLI() throws {
        let fixture = try RuntimeDiscoveryFixture()
        defer { fixture.remove() }

        let executableURL = try fixture.makeDesktopRuntime(
            appName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            version: "0.146.0"
        )
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "InfrastructureTests.\(UUID().uuidString)")
        )
        let locator = CodexLocator(
            fileManager: .default,
            preferences: AppPreferences(defaults: defaults),
            environment: fixture.environment
        )
        let discovered = expectation(description: "Desktop Runtime discovered")

        locator.discover { result in
            do {
                let candidates = try result.get()
                XCTAssertEqual(candidates.map(\.executableURL), [executableURL])
            } catch {
                XCTFail("Unexpected discovery error: \(error)")
            }
            discovered.fulfill()
        }

        wait(for: [discovered], timeout: 5)
    }

    func testIndependentCLIIsPreferredOverNewerDesktopRuntime() throws {
        let fixture = try RuntimeDiscoveryFixture()
        defer { fixture.remove() }

        let desktopURL = try fixture.makeDesktopRuntime(
            appName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            version: "0.200.0"
        )
        let independentURL = try fixture.makeIndependentRuntime(version: "0.150.0")
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "InfrastructureTests.\(UUID().uuidString)")
        )
        let preferences = AppPreferences(defaults: defaults)
        preferences.selectedCodexPath = independentURL.path
        let locator = CodexLocator(
            fileManager: .default,
            preferences: preferences,
            environment: fixture.environment
        )
        let discovered = expectation(description: "Runtime priority resolved")

        locator.discover { result in
            do {
                let candidates = try result.get()
                XCTAssertEqual(
                    candidates.map(\.executableURL),
                    [independentURL, desktopURL]
                )
            } catch {
                XCTFail("Unexpected discovery error: \(error)")
            }
            discovered.fulfill()
        }

        wait(for: [discovered], timeout: 5)
    }

    func testRejectsDesktopRuntimeWhenApplicationSignatureIsInvalid() throws {
        let fixture = try RuntimeDiscoveryFixture()
        defer { fixture.remove() }

        _ = try fixture.makeDesktopRuntime(
            appName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            version: "0.146.0"
        )
        fixture.rejectSignature(
            at: fixture.applicationsURL.appendingPathComponent("ChatGPT.app")
        )

        try assertDesktopRuntimeIsRejected(fixture)
    }

    func testCurrentDesktopIsPreferredOverNewerLegacyApp() throws {
        let fixture = try RuntimeDiscoveryFixture()
        defer { fixture.remove() }

        let currentURL = try fixture.makeDesktopRuntime(
            appName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            version: "0.146.0"
        )
        let legacyURL = try fixture.makeDesktopRuntime(
            appName: "Codex.app",
            bundleIdentifier: "com.openai.codex",
            version: "0.300.0"
        )
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "InfrastructureTests.\(UUID().uuidString)")
        )
        let locator = CodexLocator(
            fileManager: .default,
            preferences: AppPreferences(defaults: defaults),
            environment: fixture.environment
        )
        let discovered = expectation(description: "Desktop priority resolved")

        locator.discover { result in
            switch result {
            case .success(let candidates):
                XCTAssertEqual(
                    candidates.map(\.executableURL),
                    [currentURL, legacyURL]
                )
            case .failure(let error):
                XCTFail("Unexpected discovery error: \(error)")
            }
            discovered.fulfill()
        }

        wait(for: [discovered], timeout: 5)
    }

    func testRejectsDesktopRuntimeWhenExecutableSignatureIsInvalid() throws {
        let fixture = try RuntimeDiscoveryFixture()
        defer { fixture.remove() }

        let executableURL = try fixture.makeDesktopRuntime(
            appName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            version: "0.146.0"
        )
        fixture.rejectSignature(at: executableURL)

        try assertDesktopRuntimeIsRejected(fixture)
    }

    func testRejectsDesktopRuntimeWithUnexpectedBundleIdentifier() throws {
        let fixture = try RuntimeDiscoveryFixture()
        defer { fixture.remove() }

        _ = try fixture.makeDesktopRuntime(
            appName: "ChatGPT.app",
            bundleIdentifier: "com.example.untrusted",
            version: "0.146.0"
        )

        try assertDesktopRuntimeIsRejected(fixture)
    }

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
        XCTAssertEqual(DisplayErrorReason.classify(CodexLocatorError.notFound), .runtimeNotFound)
        XCTAssertEqual(
            AppLocalization(language: .english).text(
                DisplayErrorReason.classify(CodexLocatorError.notFound).localizationKey
            ),
            "Codex Runtime not found"
        )
        XCTAssertEqual(
            DisplayErrorReason.classify(CodexLocatorError.incompatible),
            .incompatibleRuntime
        )
        XCTAssertEqual(
            AppLocalization(language: .simplifiedChinese).text(
                DisplayErrorReason.classify(CodexLocatorError.incompatible).localizationKey
            ),
            "Codex Runtime 不兼容"
        )
        XCTAssertEqual(
            DisplayErrorReason.classify(WeeklyQuotaError.weeklyWindowUnavailable),
            .weeklyQuotaUnavailable
        )
        XCTAssertEqual(
            DisplayErrorReason.classify(
                AppServerClientError.server(code: 401, message: "authentication required")
            ),
            .notLoggedIn
        )
        XCTAssertEqual(DisplayErrorReason.classify(AppServerClientError.timedOut), .networkFailure)
    }

    func testStatusIndicatorUsesInsetCapsuleAndTunedDigits() {
        let bounds = NSRect(
            x: 0,
            y: 0,
            width: StatusIndicatorMetrics.statusItemWidth,
            height: 22
        )
        let ringRect = StatusIndicatorMetrics.ringRect(in: bounds)

        XCTAssertEqual(
            ringRect.width + StatusIndicatorMetrics.ringLineWidth,
            StatusIndicatorMetrics.statusItemWidth - 1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ringRect.height + StatusIndicatorMetrics.ringLineWidth,
            bounds.height - 1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            StatusIndicatorMetrics.fontSize(forCharacterCount: 1),
            12,
            accuracy: 0.001
        )
        XCTAssertEqual(
            StatusIndicatorMetrics.fontSize(forCharacterCount: 2),
            11,
            accuracy: 0.001
        )
        XCTAssertEqual(
            StatusIndicatorMetrics.fontSize(forCharacterCount: 3),
            9.6,
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

    func testStatusIndicatorUsesFiniteEmptyRectsBeforeStatusBarLayout() {
        let transientBounds = NSRect(x: 0, y: 0, width: 34, height: 0)

        for rect in [
            StatusIndicatorMetrics.ringRect(in: transientBounds),
            StatusIndicatorMetrics.glassRect(in: transientBounds)
        ] {
            XCTAssertTrue(rect.origin.x.isFinite)
            XCTAssertTrue(rect.origin.y.isFinite)
            XCTAssertTrue(rect.width.isFinite)
            XCTAssertTrue(rect.height.isFinite)
            XCTAssertEqual(rect.width, 0)
            XCTAssertEqual(rect.height, 0)
        }
    }

    @MainActor
    func testStatusIndicatorRendersTunedCapsule() throws {
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
        attachment.name = "Tuned quota indicator"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testStatusItemBecomesVisibleAfterAppKitLayout() {
        let controller = StatusMenuController()

        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let snapshot = controller.layoutSnapshot

        XCTAssertGreaterThan(snapshot.buttonBounds.height, 0)
        XCTAssertGreaterThan(snapshot.indicatorBounds.height, 0)
        XCTAssertTrue(snapshot.isAttachedToWindow)
    }

    @MainActor
    func testMenuShowsOnlyWeeklyQuotaInBothLanguages() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let controller = StatusMenuController()
        controller.update(
            state: .fresh(
                WeeklyQuotaReading(
                    remainingPercent: 42,
                    resetsAt: now.addingTimeInterval(86_400),
                    fetchedAt: now
                )
            ),
            refreshing: false,
            loginLaunchState: .enabled,
            now: now
        )

        let presentation = controller.presentationSnapshot

        XCTAssertEqual(presentation.indicatorRemainingPercent, 42)
        XCTAssertEqual(presentation.language, .english)
        XCTAssertEqual(presentation.weeklyTitle, "Weekly remaining      42%")
        XCTAssertEqual(presentation.resetTitle, "Resets in        1 day")

        controller.setLanguage(.simplifiedChinese, now: now)

        XCTAssertEqual(controller.presentationSnapshot.weeklyTitle, "周余量      42%")
        XCTAssertEqual(controller.presentationSnapshot.resetTitle, "重置倒计时    1 天")
    }

    @MainActor
    func testMenuKeepsWeeklyRowWhenQuotaIsUnavailable() {
        let controller = StatusMenuController()
        controller.update(
            state: .unavailable(.weeklyQuotaUnavailable),
            refreshing: false,
            loginLaunchState: .enabled
        )

        XCTAssertEqual(controller.presentationSnapshot.weeklyTitle, "Weekly remaining      —")
        XCTAssertEqual(
            controller.presentationSnapshot.errorTitle,
            "Reason           Weekly quota unavailable"
        )
    }

    private func assertDesktopRuntimeIsRejected(
        _ fixture: RuntimeDiscoveryFixture
    ) throws {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "InfrastructureTests.\(UUID().uuidString)")
        )
        let locator = CodexLocator(
            fileManager: .default,
            preferences: AppPreferences(defaults: defaults),
            environment: fixture.environment
        )
        let rejected = expectation(description: "Untrusted Desktop Runtime rejected")

        locator.discover { result in
            guard case .failure(CodexLocatorError.incompatible) = result else {
                XCTFail("Expected incompatible Runtime, got \(result)")
                rejected.fulfill()
                return
            }
            rejected.fulfill()
        }

        wait(for: [rejected], timeout: 5)
    }

}

private final class RuntimeDiscoveryFixture {
    let rootURL: URL
    let applicationsURL: URL
    let homeURL: URL
    private var versions: [String: String] = [:]
    private var rejectedSignaturePaths = Set<String>()

    lazy var environment = CodexLocatorEnvironment(
        executableSearchPath: "",
        homeDirectory: homeURL,
        applicationDirectories: [applicationsURL],
        runCommand: { [weak self] executableURL, arguments, _ in
            guard
                arguments == ["--version"],
                let version = self?.versions[executableURL.path]
            else {
                return .success(CommandOutput(status: 1, stdout: "", stderr: "unsupported"))
            }
            return .success(
                CommandOutput(
                    status: 0,
                    stdout: "codex-cli \(version)",
                    stderr: ""
                )
            )
        },
        isCodeSignatureValid: { [weak self] url, _ in
            self?.rejectedSignaturePaths.contains(url.path) == false
        },
        spotlightExecutablePaths: { [] },
        spotlightApplicationPaths: { [] }
    )

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexCycle-runtime-\(UUID().uuidString)")
        applicationsURL = rootURL.appendingPathComponent("Applications")
        homeURL = rootURL.appendingPathComponent("home")
        try FileManager.default.createDirectory(
            at: applicationsURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: homeURL,
            withIntermediateDirectories: true
        )
    }

    func makeDesktopRuntime(
        appName: String,
        bundleIdentifier: String,
        version: String
    ) throws -> URL {
        let appURL = applicationsURL.appendingPathComponent(appName)
        let contentsURL = appURL.appendingPathComponent("Contents")
        let resourcesURL = contentsURL.appendingPathComponent("Resources")
        let executableURL = resourcesURL.appendingPathComponent("codex")

        try FileManager.default.createDirectory(
            at: resourcesURL,
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )

        let info: [String: Any] = ["CFBundleIdentifier": bundleIdentifier]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        versions[executableURL.path] = version
        return executableURL
    }

    func makeIndependentRuntime(version: String) throws -> URL {
        let binURL = rootURL.appendingPathComponent("bin")
        let executableURL = binURL.appendingPathComponent("codex")
        try FileManager.default.createDirectory(
            at: binURL,
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )
        versions[executableURL.path] = version
        return executableURL
    }

    func rejectSignature(at url: URL) {
        rejectedSignaturePaths.insert(url.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
