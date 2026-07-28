import Darwin
import Foundation
import Security

struct CodexCandidate: Equatable {
    let executableURL: URL
    let version: SemanticVersion
}

struct SemanticVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let suffix: String?

    var description: String {
        let base = "\(major).\(minor).\(patch)"
        return suffix.map { "\(base)-\($0)" } ?? base
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        switch (lhs.suffix, rhs.suffix) {
        case (nil, nil):
            return false
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        case let (left?, right?):
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    static func parseCodexVersion(from output: String) -> SemanticVersion? {
        let pattern = #"codex-cli\s+(\d+)\.(\d+)\.(\d+)(?:-([A-Za-z0-9.-]+))?"#
        guard
            let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(
                in: output,
                range: NSRange(output.startIndex..., in: output)
            ),
            let majorRange = Range(match.range(at: 1), in: output),
            let minorRange = Range(match.range(at: 2), in: output),
            let patchRange = Range(match.range(at: 3), in: output)
        else {
            return nil
        }

        let suffix: String?
        if match.range(at: 4).location != NSNotFound,
           let suffixRange = Range(match.range(at: 4), in: output) {
            suffix = String(output[suffixRange])
        } else {
            suffix = nil
        }

        guard
            let major = Int(output[majorRange]),
            let minor = Int(output[minorRange]),
            let patch = Int(output[patchRange])
        else {
            return nil
        }

        return SemanticVersion(major: major, minor: minor, patch: patch, suffix: suffix)
    }
}

enum CodexLocatorError: Error {
    case notFound
    case incompatible
}

struct CommandOutput {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum CommandRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) -> Result<CommandOutput, Error> {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let finished = DispatchSemaphore(value: 0)

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return .failure(error)
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            return .failure(AppServerClientError.timedOut)
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

        return .success(
            CommandOutput(
                status: process.terminationStatus,
                stdout: String(decoding: stdoutData, as: UTF8.self),
                stderr: String(decoding: stderrData, as: UTF8.self)
            )
        )
    }
}

final class CodexLocator {
    private let fileManager: FileManager
    private let preferences: AppPreferences
    private let scanQueue = DispatchQueue(label: "com.fxl.codexCycle.locator", qos: .utility)

    init(
        fileManager: FileManager = .default,
        preferences: AppPreferences = AppPreferences()
    ) {
        self.fileManager = fileManager
        self.preferences = preferences
    }

    func discover(completion: @escaping (Result<[CodexCandidate], Error>) -> Void) {
        scanQueue.async {
            var paths = self.knownCandidatePaths()
            paths.formUnion(self.spotlightCandidatePaths())
            let foundOnDisk = paths.contains {
                self.fileManager.fileExists(atPath: $0)
            }

            let candidates = paths
                .compactMap { self.validatedCandidate(at: URL(fileURLWithPath: $0)) }
                .reduce(into: [String: CodexCandidate]()) { result, candidate in
                    result[candidate.executableURL.path] = candidate
                }
                .values
                .sorted {
                    if $0.version != $1.version {
                        return $0.version > $1.version
                    }
                    return $0.executableURL.path < $1.executableURL.path
                }

            DispatchQueue.main.async {
                if candidates.isEmpty {
                    completion(.failure(
                        foundOnDisk ? CodexLocatorError.incompatible : CodexLocatorError.notFound
                    ))
                } else {
                    completion(.success(Array(candidates)))
                }
            }
        }
    }

    private func knownCandidatePaths() -> Set<String> {
        var result = Set<String>()

        if let cached = preferences.selectedCodexPath {
            result.insert(cached)
        }

        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        environmentPath
            .split(separator: ":")
            .map(String.init)
            .forEach { result.insert(URL(fileURLWithPath: $0).appendingPathComponent("codex").path) }

        let home = fileManager.homeDirectoryForCurrentUser
        let fixedPaths = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/opt/local/bin/codex",
            home.appendingPathComponent(".local/bin/codex").path,
            home.appendingPathComponent(".volta/bin/codex").path,
            home.appendingPathComponent(".bun/bin/codex").path,
            home.appendingPathComponent("Library/pnpm/codex").path
        ]
        result.formUnion(fixedPaths)

        let nvmRoot = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            versions.forEach {
                result.insert($0.appendingPathComponent("bin/codex").path)
            }
        }

        return result
    }

    private func spotlightCandidatePaths() -> Set<String> {
        let result = CommandRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/mdfind"),
            arguments: ["kMDItemFSName == 'codex'cd"],
            timeout: 10
        )

        guard case .success(let output) = result, output.status == 0 else {
            return []
        }

        return Set(
            output.stdout
                .split(whereSeparator: \.isNewline)
                .map(String.init)
        )
    }

    private func validatedCandidate(at originalURL: URL) -> CodexCandidate? {
        guard fileManager.fileExists(atPath: originalURL.path) else {
            return nil
        }

        let resolvedURL = originalURL.resolvingSymlinksInPath().standardizedFileURL
        let path = resolvedURL.path
        let home = fileManager.homeDirectoryForCurrentUser.path

        if path.hasPrefix(home + "/Downloads/") || path.hasPrefix("/Volumes/") {
            return nil
        }

        guard fileManager.isExecutableFile(atPath: path) else {
            return nil
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .volumeIsLocalKey,
            .volumeIsRemovableKey
        ]
        guard
            let values = try? resolvedURL.resourceValues(forKeys: keys),
            values.isRegularFile == true,
            values.volumeIsLocal != false,
            values.volumeIsRemovable != true,
            hasSafeOwnershipAndPermissions(resolvedURL),
            hasValidCodeSignature(resolvedURL)
        else {
            return nil
        }

        guard case .success(let output) = CommandRunner.run(
            executableURL: resolvedURL,
            arguments: ["--version"],
            timeout: 5
        ), output.status == 0 else {
            return nil
        }

        let combinedOutput = output.stdout + "\n" + output.stderr
        guard let version = SemanticVersion.parseCodexVersion(from: combinedOutput) else {
            return nil
        }

        return CodexCandidate(executableURL: resolvedURL, version: version)
    }

    private func hasSafeOwnershipAndPermissions(_ executableURL: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: executableURL.path) else {
            return false
        }

        let currentUser = NSNumber(value: getuid())
        guard
            let owner = attributes[.ownerAccountID] as? NSNumber,
            owner == currentUser || owner.uint32Value == 0,
            let permissions = attributes[.posixPermissions] as? NSNumber,
            permissions.intValue & 0o022 == 0
        else {
            return false
        }

        var parent = executableURL.deletingLastPathComponent()
        while parent.path != "/" {
            guard
                let parentAttributes = try? fileManager.attributesOfItem(atPath: parent.path),
                let parentPermissions = parentAttributes[.posixPermissions] as? NSNumber,
                parentPermissions.intValue & 0o002 == 0
            else {
                return false
            }
            parent.deleteLastPathComponent()
        }

        return true
    }

    private func hasValidCodeSignature(_ executableURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            return false
        }

        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidity(staticCode, flags, nil) == errSecSuccess
    }
}
