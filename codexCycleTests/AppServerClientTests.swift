import XCTest
@testable import codexCycle

final class AppServerClientTests: XCTestCase {
    private var temporaryScripts: [URL] = []

    override func tearDown() {
        temporaryScripts.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryScripts.removeAll()
        super.tearDown()
    }

    func testInitializesReadsQuotaLimitsAndEmitsUpdateNotification() throws {
        let script = try makeScript(
            body: """
            while IFS= read -r line; do
              case "$line" in
                *rateLimits*)
                  printf '%s\\n' '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1800010000},"secondary":{"usedPercent":3,"windowDurationMins":10080,"resetsAt":1800100000}},"rateLimitsByLimitId":null}}'
                  ;;
                *initialized*)
                  printf '%s\\n' '{"method":"account/rateLimits/updated","params":{"rateLimits":{"limitId":"codex"}}}'
                  ;;
                *initialize*)
                  printf '%s\\n' '{"id":1,"result":{"userAgent":"fake/1"}}'
                  ;;
              esac
            done
            """
        )

        let client = makeClient(script)
        let update = expectation(description: "rate limit update")
        let read = expectation(description: "full rate limit read")

        client.onRateLimitsUpdated = {
            update.fulfill()
        }

        client.start { result in
            if case .failure(let error) = result {
                XCTFail("Unexpected startup error: \(error)")
            }
            client.readRateLimits { response in
                do {
                    let payload = try response.get()
                    XCTAssertEqual(payload.rateLimits.limitId, "codex")
                    XCTAssertEqual(payload.rateLimits.primary?.usedPercent, 25)
                    XCTAssertEqual(payload.rateLimits.primary?.windowDurationMins, 300)
                    XCTAssertEqual(payload.rateLimits.secondary?.usedPercent, 3)
                    XCTAssertEqual(payload.rateLimits.secondary?.windowDurationMins, 10_080)
                } catch {
                    XCTFail("Unexpected read error: \(error)")
                }
                read.fulfill()
            }
        }

        wait(for: [update, read], timeout: 5)
        client.stop()
    }

    func testCodexLaunchUsesCandidateSearchPathForEnvInterpreter() throws {
        let fixture = try makeEnvironmentDependentScript(
            body: """
            while IFS= read -r line; do
              case "$line" in
                *rateLimits*)
                  printf '%s\\n' '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1800010000},"secondary":null},"rateLimitsByLimitId":null}}'
                  ;;
                *initialized*)
                  ;;
                *initialize*)
                  printf '%s\\n' '{"id":1,"result":{"userAgent":"fake/1"}}'
                  ;;
              esac
            done
            """
        )
        let client = AppServerClient(
            configuration: .codex(
                at: fixture.scriptURL,
                executableSearchPath: fixture.executableSearchPath
            )
        )
        let read = expectation(description: "environment-dependent Runtime read")

        client.start { result in
            if case .failure(let error) = result {
                XCTFail("Unexpected startup error: \(error)")
                read.fulfill()
                return
            }
            client.readRateLimits { response in
                do {
                    let payload = try response.get()
                    XCTAssertEqual(payload.rateLimits.primary?.usedPercent, 25)
                } catch {
                    XCTFail("Unexpected read error: \(error)")
                }
                read.fulfill()
            }
        }

        wait(for: [read], timeout: 5)
        client.stop()
    }

    func testReadTimesOutWhenServerDoesNotRespond() throws {
        let script = try makeScript(
            body: """
            while IFS= read -r line; do
              case "$line" in
                *initialize*)
                  printf '%s\\n' '{"id":1,"result":{"userAgent":"fake/1"}}'
                  ;;
              esac
            done
            """
        )

        let client = makeClient(script)
        let timedOut = expectation(description: "timeout")

        client.start { result in
            if case .failure(let error) = result {
                XCTFail("Unexpected startup error: \(error)")
            }
            client.readRateLimits(timeout: 0.1) { response in
                guard case .failure(AppServerClientError.timedOut) = response else {
                    XCTFail("Expected timeout, got \(response)")
                    timedOut.fulfill()
                    return
                }
                timedOut.fulfill()
            }
        }

        wait(for: [timedOut], timeout: 5)
        client.stop()
    }

    func testReportsUnexpectedProcessExit() throws {
        let script = try makeScript(
            body: """
            while IFS= read -r line; do
              case "$line" in
                *initialized*)
                  exit 7
                  ;;
                *initialize*)
                  printf '%s\\n' '{"id":1,"result":{"userAgent":"fake/1"}}'
                  ;;
              esac
            done
            """
        )

        let client = makeClient(script)
        let exited = expectation(description: "unexpected exit")
        client.onUnexpectedTermination = { error in
            guard case AppServerClientError.processExited(7) = error else {
                XCTFail("Unexpected process error: \(error)")
                exited.fulfill()
                return
            }
            exited.fulfill()
        }

        client.start { result in
            if case .failure(let error) = result {
                XCTFail("Unexpected startup error: \(error)")
            }
        }

        wait(for: [exited], timeout: 5)
        client.stop()
    }

    private func makeClient(_ script: URL) -> AppServerClient {
        AppServerClient(
            configuration: AppServerLaunchConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [script.path]
            )
        )
    }

    private func makeScript(body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexCycle-fake-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
        temporaryScripts.append(url)
        return url
    }

    private func makeEnvironmentDependentScript(
        body: String
    ) throws -> (scriptURL: URL, executableSearchPath: String) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexCycle-env-fake-\(UUID().uuidString)")
        let binURL = rootURL.appendingPathComponent("bin")
        let packageURL = rootURL.appendingPathComponent("package")
        let interpreterURL = binURL.appendingPathComponent("codexcycle-test-node")
        let scriptURL = packageURL.appendingPathComponent("codex.js")
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
        try ("#!/usr/bin/env codexcycle-test-node\n" + body + "\n").write(
            to: scriptURL,
            atomically: true,
            encoding: .utf8
        )
        for url in [interpreterURL, scriptURL] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
        }
        temporaryScripts.append(rootURL)
        return (
            scriptURL,
            CodexProcessSearchPath.searchPath(
                inherited: "/usr/bin:/bin:/usr/sbin:/sbin",
                executableDirectory: binURL
            )
        )
    }
}
