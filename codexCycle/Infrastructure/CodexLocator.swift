import Darwin
import Foundation
import Security

struct CodexCandidate: Equatable {
    let launcherURL: URL
    let executableURL: URL
    let version: SemanticVersion
    let source: CodexRuntimeSource
    let executableSearchPath: String
}

enum CodexRuntimeSource: Int, Comparable {
    case independentCLI = 0
    case currentDesktop = 1
    case legacyDesktop = 2

    static func < (lhs: CodexRuntimeSource, rhs: CodexRuntimeSource) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
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

enum CodexProcessSearchPath {
    static func searchPath(
        inherited: String,
        executableDirectory: URL? = nil
    ) -> String {
        let inheritedPath = inherited.isEmpty
            ? "/usr/bin:/bin:/usr/sbin:/sbin"
            : inherited
        let inheritedDirectories = inheritedPath
            .split(separator: ":")
            .map(String.init)
        let candidateDirectory = executableDirectory?
            .standardizedFileURL
            .path

        var seen = Set<String>()
        return ([candidateDirectory].compactMap { $0 } + inheritedDirectories)
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
    }
}

enum CommandRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        executableSearchPath: String? = nil
    ) -> Result<CommandOutput, Error> {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let finished = DispatchSemaphore(value: 0)

        if let executableSearchPath {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "PATH=\(executableSearchPath)",
                executableURL.path
            ] + arguments
        } else {
            process.executableURL = executableURL
            process.arguments = arguments
        }
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

enum CodexCodeSignatureRequirement {
    case integrity
    case officialDesktopApplication
    case officialDesktopRuntime

    fileprivate var requirement: String? {
        let openAITeam = #"anchor apple generic and certificate leaf[subject.OU] = "2DC432GLL2""#
        switch self {
        case .integrity:
            return nil
        case .officialDesktopApplication:
            return #"identifier "com.openai.codex" and \#(openAITeam)"#
        case .officialDesktopRuntime:
            return openAITeam
        }
    }
}

enum CodeSignatureValidator {
    static func isValid(
        at url: URL,
        requirement: CodexCodeSignatureRequirement
    ) -> Bool {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            return false
        }

        var staticRequirement: SecRequirement?
        if let requirementText = requirement.requirement {
            let requirementStatus = SecRequirementCreateWithString(
                requirementText as CFString,
                SecCSFlags(),
                &staticRequirement
            )
            guard requirementStatus == errSecSuccess else {
                return false
            }
        }

        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidity(staticCode, flags, staticRequirement) == errSecSuccess
    }
}

struct CodexLocatorEnvironment {
    let executableSearchPath: String
    let homeDirectory: URL
    let applicationDirectories: [URL]
    let runCommand: (
        URL,
        [String],
        TimeInterval,
        String
    ) -> Result<CommandOutput, Error>
    let isCodeSignatureValid: (URL, CodexCodeSignatureRequirement) -> Bool
    let spotlightExecutablePaths: () -> Set<String>
    let spotlightApplicationPaths: () -> Set<String>

    static func live(fileManager: FileManager) -> CodexLocatorEnvironment {
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let executableSearchPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return CodexLocatorEnvironment(
            executableSearchPath: executableSearchPath,
            homeDirectory: homeDirectory,
            applicationDirectories: [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                homeDirectory.appendingPathComponent("Applications", isDirectory: true)
            ],
            runCommand: { executableURL, arguments, timeout, executableSearchPath in
                CommandRunner.run(
                    executableURL: executableURL,
                    arguments: arguments,
                    timeout: timeout,
                    executableSearchPath: executableSearchPath
                )
            },
            isCodeSignatureValid: CodeSignatureValidator.isValid,
            spotlightExecutablePaths: {
                spotlightPaths(query: "kMDItemFSName == 'codex'cd")
            },
            spotlightApplicationPaths: {
                spotlightPaths(query: "kMDItemCFBundleIdentifier == 'com.openai.codex'")
            }
        )
    }

    private static func spotlightPaths(query: String) -> Set<String> {
        let result = CommandRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/mdfind"),
            arguments: [query],
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
}

final class CodexLocator {
    private enum SupportedDesktopRuntime: CaseIterable {
        case current
        case legacy

        private var configuration: (applicationName: String, source: CodexRuntimeSource) {
            switch self {
            case .current:
                return ("ChatGPT.app", .currentDesktop)
            case .legacy:
                return ("Codex.app", .legacyDesktop)
            }
        }

        var applicationName: String { configuration.applicationName }
        var source: CodexRuntimeSource { configuration.source }

        init?(applicationName: String) {
            guard
                let desktop = Self.allCases.first(where: {
                    $0.applicationName == applicationName
                })
            else {
                return nil
            }
            self = desktop
        }
    }

    private struct RuntimeLocation {
        let executableURL: URL
        let source: CodexRuntimeSource
        let applicationURL: URL?
    }

    private let fileManager: FileManager
    private let preferences: AppPreferences
    private let environment: CodexLocatorEnvironment
    private let scanQueue = DispatchQueue(label: "com.fxl.codexCycle.locator", qos: .utility)

    init(
        fileManager: FileManager = .default,
        preferences: AppPreferences = AppPreferences(),
        environment: CodexLocatorEnvironment? = nil
    ) {
        self.fileManager = fileManager
        self.preferences = preferences
        self.environment = environment ?? .live(fileManager: fileManager)
    }

    func discover(completion: @escaping (Result<[CodexCandidate], Error>) -> Void) {
        scanQueue.async {
            var locations = self.knownCandidateLocations()
            locations.append(contentsOf: self.spotlightCandidateLocations())
            let foundOnDisk = locations.contains {
                self.fileManager.fileExists(atPath: $0.executableURL.path)
            }

            let candidates = locations
                .compactMap(self.validatedCandidate)
                .reduce(into: [String: CodexCandidate]()) { result, candidate in
                    let path = candidate.executableURL.path
                    if let existing = result[path] {
                        if existing.source < candidate.source {
                            return
                        }
                        if existing.source == candidate.source {
                            let existingPreservesLauncher =
                                existing.launcherURL != existing.executableURL
                            let candidatePreservesLauncher =
                                candidate.launcherURL != candidate.executableURL
                            if existingPreservesLauncher || !candidatePreservesLauncher {
                                return
                            }
                        }
                    }
                    result[path] = candidate
                }
                .values
                .sorted {
                    if $0.source != $1.source {
                        return $0.source < $1.source
                    }
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

    private func knownCandidateLocations() -> [RuntimeLocation] {
        var result: [RuntimeLocation] = []

        if let cached = preferences.selectedCodexPath {
            result.append(runtimeLocation(forExecutablePath: cached))
        }

        environment.executableSearchPath
            .split(separator: ":")
            .map(String.init)
            .forEach {
                result.append(
                    independentLocation(
                        at: URL(fileURLWithPath: $0).appendingPathComponent("codex")
                    )
                )
            }

        let home = environment.homeDirectory
        let fixedPaths = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/opt/local/bin/codex",
            home.appendingPathComponent(".local/bin/codex").path,
            home.appendingPathComponent(".volta/bin/codex").path,
            home.appendingPathComponent(".bun/bin/codex").path,
            home.appendingPathComponent("Library/pnpm/codex").path
        ]
        result.append(
            contentsOf: fixedPaths.map {
                independentLocation(at: URL(fileURLWithPath: $0))
            }
        )

        let nvmRoot = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            versions.forEach {
                result.append(
                    independentLocation(
                        at: $0.appendingPathComponent("bin/codex")
                    )
                )
            }
        }

        for directory in environment.applicationDirectories {
            result.append(
                contentsOf: SupportedDesktopRuntime.allCases.map {
                    desktopLocation(in: directory, desktop: $0)
                }
            )
        }

        return result
    }

    private func spotlightCandidateLocations() -> [RuntimeLocation] {
        let executables = environment.spotlightExecutablePaths().map {
            runtimeLocation(forExecutablePath: $0)
        }
        let applications = environment.spotlightApplicationPaths().compactMap {
            desktopLocation(forApplicationPath: $0)
        }
        return executables + applications
    }

    private func desktopLocation(
        in directory: URL,
        desktop: SupportedDesktopRuntime
    ) -> RuntimeLocation {
        let applicationURL = directory.appendingPathComponent(
            desktop.applicationName,
            isDirectory: true
        )
        return RuntimeLocation(
            executableURL: applicationURL
                .appendingPathComponent("Contents/Resources/codex"),
            source: desktop.source,
            applicationURL: applicationURL
        )
    }

    private func desktopLocation(forApplicationPath path: String) -> RuntimeLocation? {
        let applicationURL = URL(fileURLWithPath: path, isDirectory: true)
        guard
            let desktop = SupportedDesktopRuntime(
                applicationName: applicationURL.lastPathComponent
            )
        else {
            return nil
        }
        return desktopLocation(
            in: applicationURL.deletingLastPathComponent(),
            desktop: desktop
        )
    }

    private func runtimeLocation(forExecutablePath path: String) -> RuntimeLocation {
        let executableURL = URL(fileURLWithPath: path)
        let suffix = "/Contents/Resources/codex"
        guard executableURL.path.hasSuffix(suffix) else {
            return independentLocation(at: executableURL)
        }

        let applicationPath = String(executableURL.path.dropLast(suffix.count))
        let applicationURL = URL(fileURLWithPath: applicationPath, isDirectory: true)
        guard
            let desktop = SupportedDesktopRuntime(
                applicationName: applicationURL.lastPathComponent
            )
        else {
            return independentLocation(at: executableURL)
        }

        return RuntimeLocation(
            executableURL: executableURL,
            source: desktop.source,
            applicationURL: applicationURL
        )
    }

    private func independentLocation(at executableURL: URL) -> RuntimeLocation {
        RuntimeLocation(
            executableURL: executableURL,
            source: .independentCLI,
            applicationURL: nil
        )
    }

    private func validatedCandidate(_ location: RuntimeLocation) -> CodexCandidate? {
        let originalURL = location.executableURL
        guard fileManager.fileExists(atPath: originalURL.path) else {
            return nil
        }

        let resolvedURL = originalURL.resolvingSymlinksInPath().standardizedFileURL
        let launcherURL = originalURL.standardizedFileURL
        let path = resolvedURL.path
        let originalPath = launcherURL.path
        let home = fileManager.homeDirectoryForCurrentUser.path

        if path.hasPrefix(home + "/Downloads/")
            || path.hasPrefix("/Volumes/")
            || originalPath.hasPrefix(home + "/Downloads/")
            || originalPath.hasPrefix("/Volumes/") {
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
            hasSafeOwnershipAndPermissions(resolvedURL)
        else {
            return nil
        }

        let independentShebang = location.source == .independentCLI
            ? scriptShebang(at: resolvedURL)
            : nil
        if let independentShebang, independentShebang != "#!/usr/bin/env node" {
            return nil
        }
        let isIndependentScript = independentShebang != nil
        let executableDirectory = isIndependentScript
            ? launcherURL.deletingLastPathComponent()
            : nil
        guard
            let executableSearchPath = trustedExecutableSearchPath(
                prepending: executableDirectory
            ),
            !isIndependentScript || hasTrustedNodeInterpreter(in: executableSearchPath),
            hasRequiredCodeSignature(
                for: location,
                resolvedExecutableURL: resolvedURL,
                isIndependentScript: isIndependentScript
            )
        else {
            return nil
        }

        guard case .success(let output) = environment.runCommand(
            resolvedURL,
            ["--version"],
            5,
            executableSearchPath
        ), output.status == 0 else {
            return nil
        }

        let combinedOutput = output.stdout + "\n" + output.stderr
        guard let version = SemanticVersion.parseCodexVersion(from: combinedOutput) else {
            return nil
        }

        return CodexCandidate(
            launcherURL: launcherURL,
            executableURL: resolvedURL,
            version: version,
            source: location.source,
            executableSearchPath: executableSearchPath
        )
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

        return hasSafeAncestorPermissions(executableURL)
    }

    private func hasSafeAncestorPermissions(_ executableURL: URL) -> Bool {
        var parent = executableURL.standardizedFileURL.deletingLastPathComponent()
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

    private func trustedExecutableSearchPath(prepending directoryURL: URL?) -> String? {
        let requestedPath = CodexProcessSearchPath.searchPath(
            inherited: environment.executableSearchPath,
            executableDirectory: directoryURL
        )
        let fallbackPath = CodexProcessSearchPath.searchPath(
            inherited: "",
            executableDirectory: nil
        )
        let requiredDirectory = directoryURL?
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        var seen = Set<String>()
        let trustedDirectories = (requestedPath + ":" + fallbackPath)
            .split(separator: ":")
            .map(String.init)
            .compactMap { path -> String? in
                guard path.hasPrefix("/") else { return nil }
                let url = URL(fileURLWithPath: path, isDirectory: true)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                guard
                    hasSafeExecutableDirectory(url),
                    seen.insert(url.path).inserted
                else {
                    return nil
                }
                return url.path
            }

        if let requiredDirectory, !trustedDirectories.contains(requiredDirectory) {
            return nil
        }
        guard !trustedDirectories.isEmpty else {
            return nil
        }
        return trustedDirectories.joined(separator: ":")
    }

    private func hasSafeExecutableDirectory(_ directoryURL: URL) -> Bool {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .volumeIsLocalKey,
            .volumeIsRemovableKey
        ]
        guard let values = try? directoryURL.resourceValues(forKeys: keys) else {
            return false
        }
        guard values.isDirectory == true
            && values.volumeIsLocal != false
            && values.volumeIsRemovable != true
        else {
            return false
        }

        let currentUserID = getuid()
        var directory = directoryURL.standardizedFileURL
        while directory.path != "/" {
            guard
                let attributes = try? fileManager.attributesOfItem(atPath: directory.path),
                let owner = attributes[.ownerAccountID] as? NSNumber,
                let permissions = attributes[.posixPermissions] as? NSNumber
            else {
                return false
            }

            let mode = permissions.intValue
            guard mode & 0o002 == 0 else {
                return false
            }
            if mode & 0o020 != 0 {
                let isUserOwnedHomebrewDirectory = owner.uint32Value == currentUserID
                    && (directory.path == "/opt/homebrew"
                        || directory.path.hasPrefix("/opt/homebrew/"))
                guard isUserOwnedHomebrewDirectory else {
                    return false
                }
            }
            directory.deleteLastPathComponent()
        }

        return true
    }

    private func hasTrustedNodeInterpreter(in executableSearchPath: String) -> Bool {
        executableSearchPath
            .split(separator: ":")
            .map(String.init)
            .contains { directory in
                let interpreterURL = URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent("node")
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                guard fileManager.isExecutableFile(atPath: interpreterURL.path) else {
                    return false
                }
                let keys: Set<URLResourceKey> = [
                    .isRegularFileKey,
                    .volumeIsLocalKey,
                    .volumeIsRemovableKey
                ]
                guard
                    let values = try? interpreterURL.resourceValues(forKeys: keys),
                    values.isRegularFile == true,
                    values.volumeIsLocal != false,
                    values.volumeIsRemovable != true,
                    hasSafeExecutableDirectory(
                        interpreterURL.deletingLastPathComponent()
                    )
                else {
                    return false
                }
                return hasSafeOwnershipAndPermissions(interpreterURL)
            }
    }

    private func hasRequiredCodeSignature(
        for location: RuntimeLocation,
        resolvedExecutableURL: URL,
        isIndependentScript: Bool
    ) -> Bool {
        guard location.source != .independentCLI else {
            // Script launchers have no Mach-O signature; their ownership and
            // ancestor-directory checks still apply before this point.
            if isIndependentScript {
                return true
            }
            return environment.isCodeSignatureValid(resolvedExecutableURL, .integrity)
        }

        guard
            let applicationURL = location.applicationURL?.standardizedFileURL,
            bundleIdentifier(at: applicationURL) == "com.openai.codex",
            environment.isCodeSignatureValid(applicationURL, .officialDesktopApplication),
            environment.isCodeSignatureValid(resolvedExecutableURL, .officialDesktopRuntime)
        else {
            return false
        }
        return true
    }

    private func scriptShebang(at executableURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: executableURL) else {
            return nil
        }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 256)
        guard
            let text = String(data: data, encoding: .utf8),
            text.hasPrefix("#!")
        else {
            return nil
        }
        return text
            .split(maxSplits: 1, whereSeparator: \.isNewline)
            .first
            .map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }

    private func bundleIdentifier(at applicationURL: URL) -> String? {
        let infoURL = applicationURL.appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: infoURL),
            let info = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        else {
            return nil
        }
        return info["CFBundleIdentifier"] as? String
    }
}
