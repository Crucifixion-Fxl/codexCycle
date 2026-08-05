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

    func testUnsignedScriptRuntimeKeepsLauncherPathAcrossDiscovery() throws {
        let fixture = try RuntimeDiscoveryFixture()
        defer { fixture.remove() }

        let runtime = try fixture.makeEnvironmentDependentIndependentRuntime(
            version: "0.150.0"
        )
        fixture.useRealCommands()
        fixture.rejectSignature(at: runtime.resolvedURL)

        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "InfrastructureTests.\(UUID().uuidString)")
        )
        let preferences = AppPreferences(defaults: defaults)
        preferences.selectedCodexPath = runtime.launcherURL.path
        let locator = CodexLocator(
            fileManager: .default,
            preferences: preferences,
            environment: fixture.environment
        )
        let rediscovered = expectation(description: "Script Runtime rediscovered")

        locator.discover { result in
            do {
                let candidate = try XCTUnwrap(
                    result.get().first {
                        $0.executableURL == runtime.resolvedURL
                    }
                )
                XCTAssertEqual(candidate.launcherURL, runtime.launcherURL)
                XCTAssertEqual(candidate.executableURL, runtime.resolvedURL)
                XCTAssertEqual(
                    candidate.executableSearchPath
                        .split(separator: ":")
                        .first
                        .map(String.init),
                    runtime.binURL.path
                )

                preferences.selectedCodexPath = candidate.launcherURL.path
                let relaunchedLocator = CodexLocator(
                    fileManager: .default,
                    preferences: preferences,
                    environment: fixture.environment
                )
                relaunchedLocator.discover { relaunchedResult in
                    do {
                        let relaunchedCandidate = try XCTUnwrap(
                            relaunchedResult.get().first {
                                $0.executableURL == runtime.resolvedURL
                            }
                        )
                        XCTAssertEqual(
                            relaunchedCandidate.launcherURL,
                            runtime.launcherURL
                        )
                        XCTAssertEqual(
                            relaunchedCandidate.executableSearchPath
                                .split(separator: ":")
                                .first
                                .map(String.init),
                            runtime.binURL.path
                        )
                    } catch {
                        XCTFail("Unexpected rediscovery error: \(error)")
                    }
                    rediscovered.fulfill()
                }
            } catch {
                XCTFail("Unexpected discovery error: \(error)")
                rediscovered.fulfill()
            }
        }

        wait(for: [rediscovered], timeout: 5)
    }

    func testRejectsScriptRuntimeFromGroupWritableNonHomebrewBin() throws {
        let fixture = try RuntimeDiscoveryFixture()
        defer { fixture.remove() }

        let runtime = try fixture.makeEnvironmentDependentIndependentRuntime(
            version: "0.150.0"
        )
        fixture.rejectSignature(at: runtime.resolvedURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o770],
            ofItemAtPath: runtime.binURL.path
        )
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "InfrastructureTests.\(UUID().uuidString)")
        )
        let preferences = AppPreferences(defaults: defaults)
        preferences.selectedCodexPath = runtime.launcherURL.path
        let locator = CodexLocator(
            fileManager: .default,
            preferences: preferences,
            environment: fixture.environment
        )
        let rejected = expectation(description: "Unsafe script bin rejected")

        locator.discover { result in
            if case .success(let candidates) = result {
                XCTAssertFalse(
                    candidates.contains {
                        $0.executableURL == runtime.resolvedURL
                    }
                )
            }
            rejected.fulfill()
        }

        wait(for: [rejected], timeout: 5)
    }

    func testRejectsUnsignedNativeIndependentRuntime() throws {
        let fixture = try RuntimeDiscoveryFixture()
        defer { fixture.remove() }

        let executableURL = try fixture.makeIndependentNativeRuntime(
            version: "0.150.0"
        )
        fixture.rejectSignature(at: executableURL)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "InfrastructureTests.\(UUID().uuidString)")
        )
        let preferences = AppPreferences(defaults: defaults)
        preferences.selectedCodexPath = executableURL.path
        let locator = CodexLocator(
            fileManager: .default,
            preferences: preferences,
            environment: fixture.environment
        )
        let rejected = expectation(description: "Unsigned native Runtime rejected")

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
            DisplayErrorReason.classify(QuotaUsageError.noSupportedWindows),
            .supportedLimitsMissing
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
    func testMenuDistinguishesPreferredAndCurrentViewsDuringFallback() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let controller = StatusMenuController()
        controller.update(
            state: .fresh(
                QuotaUsageSnapshot(
                    fiveHour: nil,
                    weekly: QuotaUsageReading(
                        remainingPercent: 42,
                        resetsAt: now.addingTimeInterval(86_400),
                        fetchedAt: now
                    )
                )
            ),
            preferredWindow: .fiveHour,
            refreshing: false,
            loginLaunchState: .enabled,
            now: now
        )

        let presentation = controller.presentationSnapshot

        XCTAssertEqual(presentation.indicatorRemainingPercent, 42)
        XCTAssertEqual(presentation.language, .english)
        XCTAssertEqual(presentation.quotaHeaderTitle, "Display Quota")
        XCTAssertTrue(presentation.fiveHourIsPreferred)
        XCTAssertFalse(presentation.weeklyIsPreferred)
        XCTAssertEqual(presentation.fiveHourTitle, "5-hour remaining      —")
        XCTAssertEqual(presentation.weeklyTitle, "Weekly remaining      42%")
        XCTAssertEqual(
            presentation.currentViewTitle,
            "Current view     Weekly remaining (5-hour data unavailable)"
        )
        XCTAssertEqual(presentation.resetTitle, "Resets in        1 day")

        controller.setLanguage(.simplifiedChinese, now: now)
        let chinesePresentation = controller.presentationSnapshot

        XCTAssertEqual(chinesePresentation.language, .simplifiedChinese)
        XCTAssertEqual(chinesePresentation.quotaHeaderTitle, "显示限额")
        XCTAssertEqual(chinesePresentation.fiveHourTitle, "5 小时余量      —")
        XCTAssertEqual(chinesePresentation.weeklyTitle, "周余量      42%")
        XCTAssertEqual(
            chinesePresentation.currentViewTitle,
            "当前显示      周余量（5 小时数据不可用）"
        )
        XCTAssertEqual(chinesePresentation.resetTitle, "重置倒计时    1 天")
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
    private var runsRealCommands = false

    lazy var environment = CodexLocatorEnvironment(
        executableSearchPath: "",
        homeDirectory: homeURL,
        applicationDirectories: [applicationsURL],
        runCommand: { [weak self] executableURL, arguments, timeout, searchPath in
            if self?.runsRealCommands == true {
                return CommandRunner.run(
                    executableURL: executableURL,
                    arguments: arguments,
                    timeout: timeout,
                    executableSearchPath: searchPath
                )
            }
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

    func makeIndependentNativeRuntime(version: String) throws -> URL {
        let binURL = rootURL.appendingPathComponent("native-bin")
        let executableURL = binURL.appendingPathComponent("codex")
        try FileManager.default.createDirectory(
            at: binURL,
            withIntermediateDirectories: true
        )
        try Data([0xcf, 0xfa, 0xed, 0xfe]).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )
        versions[executableURL.path] = version
        return executableURL
    }

    func makeEnvironmentDependentIndependentRuntime(
        version: String
    ) throws -> (launcherURL: URL, resolvedURL: URL, binURL: URL) {
        let binURL = rootURL.appendingPathComponent("environment-bin")
        let packageURL = rootURL.appendingPathComponent("package")
        let launcherURL = binURL.appendingPathComponent("codex")
        let interpreterURL = binURL.appendingPathComponent("codexcycle-test-node")
        let resolvedURL = packageURL.appendingPathComponent("codex.js")
        try FileManager.default.createDirectory(
            at: binURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: packageURL,
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexec /bin/sh \"$@\"\n".write(
            to: interpreterURL,
            atomically: true,
            encoding: .utf8
        )
        try """
        #!/usr/bin/env codexcycle-test-node
        printf 'codex-cli \(version)\\n'
        """.write(to: resolvedURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: interpreterURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: resolvedURL.path
        )
        try FileManager.default.createSymbolicLink(
            at: launcherURL,
            withDestinationURL: resolvedURL
        )
        versions[resolvedURL.path] = version
        return (launcherURL, resolvedURL, binURL)
    }

    func useRealCommands() {
        runsRealCommands = true
    }

    func rejectSignature(at url: URL) {
        rejectedSignaturePaths.insert(url.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
