import AppKit
import Darwin
import ServiceManagement
import XCTest
@testable import codexCycle

final class InfrastructureTests: XCTestCase {
    func testStatusIndicatorGradientUsesRedYellowGreenAnchors() {
        XCTAssertEqual(UsageGradient.color(at: 0), UsageGradient.red)
        XCTAssertEqual(UsageGradient.color(at: 20), UsageGradient.yellow)
        XCTAssertEqual(UsageGradient.color(at: 50), UsageGradient.green)
        XCTAssertEqual(UsageGradient.color(at: 100), UsageGradient.green)
    }

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

    @MainActor
    func testServiceMigratesResolvedScriptPreferenceToLauncher() throws {
        let fixture = try RuntimeDiscoveryFixture()
        defer { fixture.remove() }

        let runtime = try fixture.makeEnvironmentDependentIndependentRuntime(
            version: "9.999.0"
        )
        fixture.useRealCommands()
        fixture.rejectSignature(at: runtime.resolvedURL)

        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "InfrastructureTests.\(UUID().uuidString)")
        )
        let preferences = AppPreferences(defaults: defaults)
        preferences.selectedCodexPath = runtime.resolvedURL.path
        let locator = CodexLocator(
            fileManager: .default,
            preferences: preferences,
            environment: fixture.makeEnvironment(
                executableSearchPath: runtime.binURL.path
            )
        )
        let service = CodexUsageService(locator: locator, preferences: preferences)
        let fetched = expectation(description: "Runtime fetched through migrated launcher")

        service.fetch { result in
            if case .failure(let error) = result {
                XCTFail("Unexpected fetch error: \(error)")
            }
            fetched.fulfill()
        }

        wait(for: [fetched], timeout: 5)
        XCTAssertEqual(preferences.selectedCodexPath, runtime.launcherURL.path)
        service.stop()

        let relaunchedLocator = CodexLocator(
            fileManager: .default,
            preferences: preferences,
            environment: fixture.makeEnvironment(executableSearchPath: "")
        )
        let rediscovered = expectation(description: "Migrated launcher survives minimal PATH")
        relaunchedLocator.discover { result in
            do {
                let candidate = try XCTUnwrap(
                    result.get().first { $0.executableURL == runtime.resolvedURL }
                )
                XCTAssertEqual(candidate.launcherURL, runtime.launcherURL)
            } catch {
                XCTFail("Unexpected rediscovery error: \(error)")
            }
            rediscovered.fulfill()
        }

        wait(for: [rediscovered], timeout: 5)
    }

    func testRejectsScriptInterpreterFromUnsafeInheritedPath() throws {
        let fixture = try RuntimeDiscoveryFixture()
        defer { fixture.remove() }

        let runtime = try fixture.makeEnvironmentDependentIndependentRuntime(
            version: "9.999.0"
        )
        let unsafeBinURL = fixture.rootURL.appendingPathComponent("unsafe-bin")
        try FileManager.default.createDirectory(
            at: unsafeBinURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(
            at: runtime.binURL.appendingPathComponent("node"),
            to: unsafeBinURL.appendingPathComponent("node")
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: unsafeBinURL.path
        )
        fixture.useRealCommands()

        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "InfrastructureTests.\(UUID().uuidString)")
        )
        let preferences = AppPreferences(defaults: defaults)
        preferences.selectedCodexPath = runtime.launcherURL.path
        let locator = CodexLocator(
            fileManager: .default,
            preferences: preferences,
            environment: fixture.makeEnvironment(
                executableSearchPath: unsafeBinURL.path
            )
        )
        let rejected = expectation(description: "Unsafe inherited interpreter rejected")

        locator.discover { result in
            if case .success(let candidates) = result {
                XCTAssertFalse(
                    candidates.contains { $0.executableURL == runtime.resolvedURL }
                )
            }
            rejected.fulfill()
        }

        wait(for: [rejected], timeout: 5)
    }

    func testRejectsUnsupportedIndependentScriptShebang() throws {
        let fixture = try RuntimeDiscoveryFixture()
        defer { fixture.remove() }

        let binURL = fixture.rootURL.appendingPathComponent("unsupported-bin")
        let executableURL = binURL.appendingPathComponent("codex")
        try FileManager.default.createDirectory(
            at: binURL,
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nprintf 'codex-cli 9.999.0\\n'\n".write(
            to: executableURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )

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
        let rejected = expectation(description: "Unsupported shebang rejected")

        locator.discover { result in
            if case .success(let candidates) = result {
                XCTAssertFalse(
                    candidates.contains { $0.executableURL == executableURL }
                )
            }
            rejected.fulfill()
        }

        wait(for: [rejected], timeout: 5)
    }

    func testNonRegularCandidateDoesNotBlockDiscovery() throws {
        let fixture = try RuntimeDiscoveryFixture()
        defer { fixture.remove() }

        let binURL = fixture.rootURL.appendingPathComponent("fifo-bin")
        let fifoURL = binURL.appendingPathComponent("codex")
        try FileManager.default.createDirectory(
            at: binURL,
            withIntermediateDirectories: true
        )
        let status = fifoURL.path.withCString { path in
            Darwin.mkfifo(path, 0o700)
        }
        XCTAssertEqual(status, 0)

        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "InfrastructureTests.\(UUID().uuidString)")
        )
        let preferences = AppPreferences(defaults: defaults)
        preferences.selectedCodexPath = fifoURL.path
        let locator = CodexLocator(
            fileManager: .default,
            preferences: preferences,
            environment: fixture.environment
        )
        let completed = expectation(description: "FIFO candidate skipped")

        locator.discover { _ in completed.fulfill() }

        wait(for: [completed], timeout: 1)
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

    func testStableErrorClassification() throws {
        XCTAssertEqual(DisplayErrorReason.classify(CodexLocatorError.notFound), .runtimeNotFound)
        XCTAssertEqual(
            try localization(for: "en").text(
                DisplayErrorReason.classify(CodexLocatorError.notFound).localizationKey
            ),
            "Codex Runtime not found"
        )
        XCTAssertEqual(
            DisplayErrorReason.classify(CodexLocatorError.incompatible),
            .incompatibleRuntime
        )
        XCTAssertEqual(
            try localization(for: "zh-Hans").text(
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
    func testMenuShowsFiveHourAndWeeklyQuotaInSupportedSystemLanguages() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let englishController = StatusMenuController(language: .english)
        englishController.update(
            state: .fresh(
                QuotaUsageSnapshot(
                    fiveHour: QuotaUsageReading(
                        remainingPercent: 75,
                        resetsAt: now.addingTimeInterval(3_600),
                        fetchedAt: now
                    ),
                    weekly: QuotaUsageReading(
                        remainingPercent: 42,
                        resetsAt: now.addingTimeInterval(86_400),
                        fetchedAt: now
                    )
                )
            ),
            refreshing: false,
            canRequest: true,
            loginLaunchState: .enabled,
            now: now
        )

        let presentation = englishController.presentationSnapshot

        XCTAssertEqual(presentation.indicatorRemainingPercent, 75)
        XCTAssertEqual(presentation.panelRemainingPercent, 75)
        XCTAssertEqual(presentation.panelQuotaTitle, "5-hour remaining")
        XCTAssertEqual(presentation.panelResetTitle, "Resets in 1 hour")
        XCTAssertEqual(
            presentation.panelSummaryTitle,
            "Weekly remaining 42%   ·   resets in 1 day"
        )
        XCTAssertEqual(presentation.fiveHourTitle, "5-hour remaining      75%")
        XCTAssertEqual(presentation.fiveHourResetTitle, "5-hour resets in  1 hour")
        XCTAssertEqual(presentation.weeklyTitle, "Weekly remaining      42%")
        XCTAssertEqual(presentation.weeklyResetTitle, "Weekly resets in  1 day")
        XCTAssertEqual(presentation.requestTitle, "Request Now")
        XCTAssertTrue(presentation.requestIsEnabled)
        XCTAssertTrue(presentation.englishLanguageIsSelected)

        englishController.setLanguage(.simplifiedChinese, now: now)
        XCTAssertEqual(englishController.presentationSnapshot.language, .simplifiedChinese)
        XCTAssertEqual(englishController.presentationSnapshot.requestTitle, "立即请求")

        let chineseController = StatusMenuController(language: .simplifiedChinese)
        chineseController.update(
            state: .fresh(
                QuotaUsageSnapshot(
                    fiveHour: QuotaUsageReading(
                        remainingPercent: 75,
                        resetsAt: now.addingTimeInterval(3_600),
                        fetchedAt: now
                    ),
                    weekly: QuotaUsageReading(
                        remainingPercent: 42,
                        resetsAt: now.addingTimeInterval(86_400),
                        fetchedAt: now
                    )
                )
            ),
            refreshing: false,
            loginLaunchState: .enabled,
            now: now
        )

        XCTAssertEqual(chineseController.presentationSnapshot.fiveHourTitle, "5 小时余量      75%")
        XCTAssertEqual(chineseController.presentationSnapshot.fiveHourResetTitle, "5 小时重置    1 小时")
        XCTAssertEqual(chineseController.presentationSnapshot.weeklyTitle, "周余量      42%")
        XCTAssertEqual(chineseController.presentationSnapshot.weeklyResetTitle, "周重置倒计时  1 天")
        XCTAssertEqual(chineseController.presentationSnapshot.panelRemainingPercent, 75)
        XCTAssertEqual(chineseController.presentationSnapshot.panelQuotaTitle, "5 小时余量")
        XCTAssertEqual(chineseController.presentationSnapshot.panelResetTitle, "1 小时后重置")
        XCTAssertEqual(
            chineseController.presentationSnapshot.panelSummaryTitle,
            "周余量 42%   ·   周重置 1 天"
        )
        XCTAssertEqual(chineseController.presentationSnapshot.requestTitle, "立即请求")
        XCTAssertTrue(
            chineseController.presentationSnapshot.simplifiedChineseLanguageIsSelected
        )
    }

    @MainActor
    func testPlusWeeklyTextShowsCompleteVisibleExpansionOnHover() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let controller = StatusMenuController(language: .english)
        controller.update(
            state: .fresh(
                QuotaUsageSnapshot(
                    fiveHour: QuotaUsageReading(
                        remainingPercent: 75,
                        resetsAt: now.addingTimeInterval(4 * 3_600 + 59 * 60),
                        fetchedAt: now
                    ),
                    weekly: QuotaUsageReading(
                        remainingPercent: 42,
                        resetsAt: now.addingTimeInterval(6 * 86_400 + 23 * 3_600),
                        fetchedAt: now
                    )
                )
            ),
            refreshing: false,
            canRequest: true,
            loginLaunchState: .enabled,
            now: now
        )

        XCTAssertTrue(controller.hasTruncatedDynamicText)
        controller.simulateQuotaSummaryHoverForTesting()

        XCTAssertTrue(controller.hoverExpansionSnapshot.isVisible)
        XCTAssertEqual(
            controller.hoverExpansionSnapshot.text,
            "Weekly remaining 42%   ·   resets in 6 days 23 hours"
        )

        controller.simulateQuotaSummaryExitForTesting()
        XCTAssertFalse(controller.hoverExpansionSnapshot.isVisible)
        XCTAssertNil(controller.hoverExpansionSnapshot.text)
    }

    @MainActor
    func testMenuDefaultsToFollowSystemAndDisablesRequestWithoutRuntime() {
        let controller = StatusMenuController()

        let presentation = controller.presentationSnapshot

        XCTAssertEqual(presentation.language, .system)
        XCTAssertTrue(presentation.systemLanguageIsSelected)
        XCTAssertFalse(presentation.requestIsEnabled)
    }

    @MainActor
    func testRequestButtonShowsRequestLifecycleFeedback() {
        let controller = StatusMenuController(language: .english)

        controller.update(
            state: .unavailable(nil),
            refreshing: false,
            requestFeedback: .requesting,
            canRequest: true,
            loginLaunchState: .enabled
        )
        XCTAssertEqual(controller.presentationSnapshot.requestTitle, "Requesting…")
        XCTAssertFalse(controller.presentationSnapshot.requestIsEnabled)

        controller.update(
            state: .unavailable(nil),
            refreshing: false,
            requestFeedback: .succeeded,
            canRequest: true,
            loginLaunchState: .enabled
        )
        XCTAssertEqual(controller.presentationSnapshot.requestTitle, "Request Succeeded")
        XCTAssertFalse(controller.presentationSnapshot.requestIsEnabled)

        controller.setLanguage(.simplifiedChinese)
        controller.update(
            state: .unavailable(nil),
            refreshing: false,
            requestFeedback: .failed,
            canRequest: true,
            loginLaunchState: .enabled
        )
        XCTAssertEqual(controller.presentationSnapshot.requestTitle, "请求失败")
        XCTAssertFalse(controller.presentationSnapshot.requestIsEnabled)

        controller.update(
            state: .unavailable(nil),
            refreshing: false,
            requestFeedback: .idle,
            canRequest: true,
            loginLaunchState: .enabled
        )
        XCTAssertEqual(controller.presentationSnapshot.requestTitle, "立即请求")
        XCTAssertTrue(controller.presentationSnapshot.requestIsEnabled)
    }

    @MainActor
    func testLanguageSelectionSliderMovesToSelectedSegmentAndRespectsReduceMotion() {
        let control = LanguageSegmentedControl(labels: ["System", "EN", "简中"])
        control.frame = NSRect(x: 0, y: 0, width: 276, height: 32)

        control.setSelectedSegment(2, animated: true, reduceMotion: true)
        XCTAssertEqual(control.selectedSegment, 2)
        XCTAssertEqual(control.selectionPosition, 2)

        control.setSelectedSegment(0, animated: true, reduceMotion: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))

        XCTAssertGreaterThan(control.selectionPosition, 0.01)
        XCTAssertLessThan(control.selectionPosition, 1.99)

        RunLoop.main.run(until: Date().addingTimeInterval(0.27))

        XCTAssertEqual(control.selectedSegment, 0)
        XCTAssertEqual(control.selectionPosition, 0, accuracy: 0.01)
    }

    @MainActor
    func testMenuKeepsBothRowsWhenQuotaIsUnavailable() throws {
        let controller = StatusMenuController(language: .english)
        controller.update(
            state: .unavailable(.supportedLimitsMissing),
            refreshing: false,
            loginLaunchState: .enabled
        )

        XCTAssertEqual(controller.presentationSnapshot.fiveHourTitle, "5-hour remaining      —")
        XCTAssertEqual(controller.presentationSnapshot.weeklyTitle, "Weekly remaining      —")
        XCTAssertEqual(
            controller.presentationSnapshot.errorTitle,
            "Reason           5-hour and weekly quotas unavailable"
        )
    }

    @MainActor
    func testCompactPanelMatchesReferenceLayout() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let controller = StatusMenuController(language: .english)
        controller.update(
            state: .fresh(
                QuotaUsageSnapshot(
                    fiveHour: nil,
                    weekly: QuotaUsageReading(
                        remainingPercent: 88,
                        resetsAt: now.addingTimeInterval(5 * 86_400 + 8 * 3_600),
                        fetchedAt: now
                    )
                )
            ),
            refreshing: false,
            canRequest: true,
            loginLaunchState: .enabled,
            now: now
        )

        XCTAssertEqual(controller.presentationSnapshot.panelRemainingPercent, 88)
        XCTAssertEqual(controller.presentationSnapshot.indicatorRemainingPercent, 88)
        XCTAssertEqual(controller.presentationSnapshot.panelQuotaTitle, "Weekly remaining")
        XCTAssertEqual(
            controller.presentationSnapshot.panelResetTitle,
            "Resets in 5 days 8 hours"
        )
        XCTAssertEqual(
            controller.presentationSnapshot.panelSummaryTitle,
            "5-hour remaining —   ·   resets in —"
        )
        XCTAssertEqual(
            controller.presentationSnapshot.loginLaunchTitle,
            "Launch at Login"
        )
        XCTAssertTrue(controller.presentationSnapshot.loginLaunchIsEnabled)
        XCTAssertEqual(controller.loginLaunchSwitchTrackColor, .systemGreen)

        let image = try XCTUnwrap(controller.renderedMenuImage())
        let data = try XCTUnwrap(image.tiffRepresentation)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: data))
        let pngData = try XCTUnwrap(
            representation.representation(using: .png, properties: [:])
        )

        XCTAssertEqual(image.size, NSSize(width: 300, height: 378))
        let attachment = XCTAttachment(
            data: pngData,
            uniformTypeIdentifier: "public.png"
        )
        attachment.name = "Compact usage panel"
        attachment.lifetime = .keepAlways
        add(attachment)

        var requestedLoginLaunchState: Bool?
        controller.onSetLoginLaunchEnabled = {
            requestedLoginLaunchState = $0
        }
        controller.simulateLoginLaunchToggleForTesting(isEnabled: false)
        XCTAssertEqual(requestedLoginLaunchState, false)
    }

    @MainActor
    func testUsageSurfaceIsPersistentFloatingPanel() {
        let controller = StatusMenuController(language: .simplifiedChinese)
        let panel = controller.panelLayoutSnapshot

        XCTAssertEqual(panel.contentSize, NSSize(width: 300, height: 378))
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(panel.level, .popUpMenu)
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertFalse(panel.hidesOnDeactivate)
    }

    @MainActor
    func testStatusItemToggleSurvivesActivationTransition() {
        let controller = StatusMenuController(language: .simplifiedChinese)

        controller.perform(NSSelectorFromString("togglePanel"))
        XCTAssertTrue(controller.panelLayoutSnapshot.isVisible)

        NotificationCenter.default.post(
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )

        XCTAssertTrue(
            controller.panelLayoutSnapshot.isVisible,
            "Opening from the status item must not immediately dismiss the panel"
        )
    }

    func testLoginItemManagerTogglesMainAppWithoutOpeningSystemSettings() throws {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "InfrastructureTests.\(UUID().uuidString)")
        )
        let preferences = AppPreferences(defaults: defaults)
        let service = FakeLoginItemService(status: .notRegistered)
        let manager = LoginItemManager(
            preferences: preferences,
            service: service
        )

        XCTAssertEqual(manager.state, .disabled)
        XCTAssertEqual(manager.setEnabled(true), .enabled)
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(manager.setEnabled(false), .disabled)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertTrue(preferences.attemptedLoginRegistration)
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

private final class FakeLoginItemService: LoginItemServicing {
    var status: SMAppService.Status
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        status = .notRegistered
    }
}

private final class RuntimeDiscoveryFixture {
    let rootURL: URL
    let applicationsURL: URL
    let homeURL: URL
    private var versions: [String: String] = [:]
    private var rejectedSignaturePaths = Set<String>()
    private var runsRealCommands = false

    lazy var environment = makeEnvironment(executableSearchPath: "")

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

    func makeEnvironment(executableSearchPath: String) -> CodexLocatorEnvironment {
        CodexLocatorEnvironment(
            executableSearchPath: executableSearchPath,
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
                    return .success(
                        CommandOutput(status: 1, stdout: "", stderr: "unsupported")
                    )
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
        try Data([0xcf, 0xfa, 0xed, 0xfe]).write(to: executableURL)
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
        let interpreterURL = binURL.appendingPathComponent("node")
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
        #!/usr/bin/env node
        if [ "${1:-}" = "--version" ]; then
          printf 'codex-cli \(version)\\n'
          exit 0
        fi
        if [ "${1:-}" = "app-server" ]; then
          while IFS= read -r line; do
            case "$line" in
              *rateLimits*)
                printf '%s\\n' '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":1800010000},"secondary":null},"rateLimitsByLimitId":null}}'
                ;;
              *initialized*)
                ;;
              *initialize*)
                printf '%s\\n' '{"id":1,"result":{"userAgent":"fake/1"}}'
                ;;
            esac
          done
          exit 0
        fi
        exit 1
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
