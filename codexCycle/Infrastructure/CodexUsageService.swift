import Foundation
import OSLog

enum DisplayErrorReason: Equatable {
    case runtimeNotFound
    case incompatibleRuntime
    case notLoggedIn
    case weeklyQuotaUnavailable
    case networkFailure
    case serviceUnavailable

    var localizationKey: String {
        switch self {
        case .runtimeNotFound:
            return "error.runtime_not_found"
        case .incompatibleRuntime:
            return "error.incompatible_runtime"
        case .notLoggedIn:
            return "error.not_logged_in"
        case .weeklyQuotaUnavailable:
            return "error.weekly_quota_unavailable"
        case .networkFailure:
            return "error.network_failure"
        case .serviceUnavailable:
            return "error.service_unavailable"
        }
    }

    static func classify(_ error: Error) -> DisplayErrorReason {
        if let locatorError = error as? CodexLocatorError {
            switch locatorError {
            case .notFound:
                return .runtimeNotFound
            case .incompatible:
                return .incompatibleRuntime
            }
        }

        if let quotaError = error as? WeeklyQuotaError {
            switch quotaError {
            case .noMainCodexBucket, .weeklyWindowUnavailable:
                return .weeklyQuotaUnavailable
            }
        }

        if let appServerError = error as? AppServerClientError {
            switch appServerError {
            case .launchFailed, .malformedResponse:
                return .incompatibleRuntime
            case .server(_, let message):
                let lowercased = message.lowercased()
                if lowercased.contains("sign in")
                    || lowercased.contains("login")
                    || lowercased.contains("auth")
                    || lowercased.contains("unauthorized") {
                    return .notLoggedIn
                }
                if lowercased.contains("network")
                    || lowercased.contains("connect")
                    || lowercased.contains("dns")
                    || lowercased.contains("offline") {
                    return .networkFailure
                }
                return .serviceUnavailable
            case .timedOut:
                return .networkFailure
            case .notRunning, .processExited, .writeFailed:
                return .serviceUnavailable
            }
        }

        let text = error.localizedDescription.lowercased()
        if text.contains("network")
            || text.contains("connect")
            || text.contains("dns")
            || text.contains("offline") {
            return .networkFailure
        }
        return .serviceUnavailable
    }
}

final class CodexUsageService {
    private let locator: CodexLocator
    private let preferences: AppPreferences
    private let logger = Logger(subsystem: "com.fxl.codexCycle", category: "usage-service")

    private var client: AppServerClient?
    private var connecting = false
    private var queuedCompletions: [(Result<WeeklyQuotaReading, Error>) -> Void] = []

    var onRateLimitsUpdated: (() -> Void)?
    var onUnexpectedTermination: ((Error) -> Void)?

    init(
        locator: CodexLocator,
        preferences: AppPreferences
    ) {
        self.locator = locator
        self.preferences = preferences
    }

    func fetch(completion: @escaping (Result<WeeklyQuotaReading, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))

        if let client {
            readWeeklyQuota(from: client, completion: completion)
            return
        }

        queuedCompletions.append(completion)
        guard !connecting else { return }
        connecting = true

        locator.discover { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let candidates):
                self.tryCandidate(candidates, at: 0)
            case .failure(let error):
                self.finishConnection(.failure(error))
            }
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        client?.stop()
        client = nil
        connecting = false
        queuedCompletions.removeAll()
    }

    func resetConnection() {
        dispatchPrecondition(condition: .onQueue(.main))
        client?.stop()
        client = nil
    }

    private func tryCandidate(_ candidates: [CodexCandidate], at index: Int) {
        guard index < candidates.count else {
            finishConnection(.failure(CodexLocatorError.incompatible))
            return
        }

        let candidate = candidates[index]
        let candidateClient = AppServerClient(
            configuration: .codex(
                at: candidate.executableURL,
                executableSearchPath: candidate.executableSearchPath
            )
        )

        candidateClient.onRateLimitsUpdated = { [weak self] in
            self?.onRateLimitsUpdated?()
        }
        candidateClient.onUnexpectedTermination = { [weak self, weak candidateClient] error in
            guard let self, self.client === candidateClient else { return }
            self.client = nil
            self.onUnexpectedTermination?(error)
        }

        candidateClient.start { [weak self] result in
            guard let self else { return }

            switch result {
            case .success:
                candidateClient.readRateLimits { response in
                    switch response {
                    case .success(let payload):
                        self.client = candidateClient
                        self.preferences.selectedCodexPath = candidate.launcherURL.path
                        self.preferences.selectedCodexVersion = candidate.version.description
                        do {
                            let reading = try WeeklyQuotaParser.parse(payload)
                            self.finishConnection(.success(reading))
                        } catch {
                            self.finishConnection(.failure(error))
                        }
                    case .failure(let error):
                        if self.isIncompatibleRuntime(error) {
                            candidateClient.stop()
                            self.tryCandidate(candidates, at: index + 1)
                        } else {
                            // The protocol is present even if account or network state blocks this read.
                            self.client = candidateClient
                            self.preferences.selectedCodexPath = candidate.launcherURL.path
                            self.preferences.selectedCodexVersion = candidate.version.description
                            self.finishConnection(.failure(error))
                        }
                    }
                }
            case .failure:
                candidateClient.stop()
                self.tryCandidate(candidates, at: index + 1)
            }
        }
    }

    private func finishConnection(_ result: Result<WeeklyQuotaReading, Error>) {
        connecting = false
        let completions = queuedCompletions
        queuedCompletions.removeAll()
        completions.forEach { $0(result) }
    }

    private func readWeeklyQuota(
        from client: AppServerClient,
        completion: @escaping (Result<WeeklyQuotaReading, Error>) -> Void
    ) {
        client.readRateLimits { result in
            switch result {
            case .success(let payload):
                do {
                    completion(.success(try WeeklyQuotaParser.parse(payload)))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                self.logger.error("Failed to refresh Codex quota usage")
                completion(.failure(error))
            }
        }
    }

    private func isIncompatibleRuntime(_ error: Error) -> Bool {
        guard let appServerError = error as? AppServerClientError else {
            return false
        }
        switch appServerError {
        case .malformedResponse:
            return true
        case .server(let code, _):
            return code == -32_601
        default:
            return false
        }
    }
}
