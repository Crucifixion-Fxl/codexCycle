import Foundation
import OSLog

struct AppServerLaunchConfiguration {
    let executableURL: URL
    let arguments: [String]

    static func codex(at executableURL: URL) -> AppServerLaunchConfiguration {
        AppServerLaunchConfiguration(
            executableURL: executableURL,
            arguments: ["app-server", "--stdio"]
        )
    }
}

enum AppServerClientError: Error {
    case launchFailed(String)
    case notRunning
    case processExited(Int32)
    case timedOut
    case malformedResponse
    case server(code: Int, message: String)
    case writeFailed(String)
}

final class AppServerClient {
    private struct PendingRequest {
        let completion: (Result<Data, Error>) -> Void
        let timeout: DispatchWorkItem
    }

    private struct IncomingHeader: Decodable {
        let id: Int?
        let method: String?
    }

    private struct RPCErrorPayload: Decodable {
        let code: Int
        let message: String
    }

    private struct RPCResponse<Value: Decodable>: Decodable {
        let id: Int
        let result: Value?
        let error: RPCErrorPayload?
    }

    private struct RPCRequest<Params: Encodable>: Encodable {
        let method: String
        let id: Int
        let params: Params
    }

    private struct RPCNotification<Params: Encodable>: Encodable {
        let method: String
        let params: Params
    }

    private struct InitializeParams: Encodable {
        struct ClientInfo: Encodable {
            let name: String
            let version: String
        }

        let clientInfo: ClientInfo
    }

    private struct InitializeResult: Decodable {
        let userAgent: String
    }

    private struct EmptyParams: Codable {}

    private let configuration: AppServerLaunchConfiguration
    private let queue = DispatchQueue(label: "com.fxl.codexCycle.app-server")
    private let logger = Logger(subsystem: "com.fxl.codexCycle", category: "app-server")
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()
    private var nextRequestID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var stoppingIntentionally = false
    private var initialized = false

    var onRateLimitsUpdated: (() -> Void)?
    var onUnexpectedTermination: ((Error) -> Void)?

    init(configuration: AppServerLaunchConfiguration) {
        self.configuration = configuration
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            if self.initialized, self.process?.isRunning == true {
                DispatchQueue.main.async { completion(.success(())) }
                return
            }

            self.startProcess(completion: completion)
        }
    }

    func readRateLimits(
        timeout: TimeInterval = 15,
        completion: @escaping (Result<GetAccountRateLimitsResult, Error>) -> Void
    ) {
        queue.async {
            guard self.initialized, self.process?.isRunning == true else {
                DispatchQueue.main.async { completion(.failure(AppServerClientError.notRunning)) }
                return
            }

            self.sendRequest(
                method: "account/rateLimits/read",
                params: EmptyParams(),
                timeout: timeout,
                completion: completion
            )
        }
    }

    func stop() {
        queue.sync {
            stoppingIntentionally = true
            initialized = false

            stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            stderrPipe?.fileHandleForReading.readabilityHandler = nil

            pending.values.forEach {
                $0.timeout.cancel()
                $0.completion(.failure(AppServerClientError.notRunning))
            }
            pending.removeAll()

            if process?.isRunning == true {
                process?.terminate()
            }

            try? stdinPipe?.fileHandleForWriting.close()
            process = nil
            stdinPipe = nil
            stdoutPipe = nil
            stderrPipe = nil
            stdoutBuffer.removeAll(keepingCapacity: false)
        }
    }

    private func startProcess(completion: @escaping (Result<Void, Error>) -> Void) {
        stoppingIntentionally = false
        initialized = false
        stdoutBuffer.removeAll(keepingCapacity: true)

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async {
                self?.consumeStdout(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.logger.debug("Codex app-server emitted a diagnostic message")
        }

        process.terminationHandler = { [weak self] process in
            self?.queue.async {
                self?.handleTermination(status: process.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                completion(.failure(AppServerClientError.launchFailed(error.localizedDescription)))
            }
            return
        }

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe

        sendRequest(
            method: "initialize",
            params: InitializeParams(
                clientInfo: .init(name: "codexCycle", version: appVersion)
            ),
            timeout: 15
        ) { [weak self] (result: Result<InitializeResult, Error>) in
            guard let self else { return }

            switch result {
            case .success:
                self.queue.async {
                    self.sendNotification(method: "initialized", params: EmptyParams())
                    self.initialized = true
                    DispatchQueue.main.async { completion(.success(())) }
                }
            case .failure(let error):
                self.stop()
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private func sendRequest<Params: Encodable, Value: Decodable>(
        method: String,
        params: Params,
        timeout: TimeInterval,
        completion: @escaping (Result<Value, Error>) -> Void
    ) {
        guard process?.isRunning == true, let input = stdinPipe?.fileHandleForWriting else {
            DispatchQueue.main.async { completion(.failure(AppServerClientError.notRunning)) }
            return
        }

        let id = nextRequestID
        nextRequestID += 1

        let request = RPCRequest(method: method, id: id, params: params)
        let payload: Data
        do {
            payload = try encoder.encode(request) + Data([0x0A])
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
            return
        }

        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self, let request = self.pending.removeValue(forKey: id) else { return }
            DispatchQueue.main.async {
                request.completion(.failure(AppServerClientError.timedOut))
            }
        }

        pending[id] = PendingRequest(
            completion: { [weak self] result in
                guard let self else { return }

                let decoded: Result<Value, Error>
                switch result {
                case .success(let data):
                    do {
                        let response = try self.decoder.decode(RPCResponse<Value>.self, from: data)
                        if let error = response.error {
                            decoded = .failure(
                                AppServerClientError.server(code: error.code, message: error.message)
                            )
                        } else if let value = response.result {
                            decoded = .success(value)
                        } else {
                            decoded = .failure(AppServerClientError.malformedResponse)
                        }
                    } catch {
                        decoded = .failure(AppServerClientError.malformedResponse)
                    }
                case .failure(let error):
                    decoded = .failure(error)
                }

                DispatchQueue.main.async { completion(decoded) }
            },
            timeout: timeoutWork
        )

        queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        do {
            try input.write(contentsOf: payload)
        } catch {
            pending.removeValue(forKey: id)?.timeout.cancel()
            DispatchQueue.main.async {
                completion(.failure(AppServerClientError.writeFailed(error.localizedDescription)))
            }
        }
    }

    private func sendNotification<Params: Encodable>(method: String, params: Params) {
        guard process?.isRunning == true, let input = stdinPipe?.fileHandleForWriting else {
            return
        }

        do {
            let payload = try encoder.encode(RPCNotification(method: method, params: params))
                + Data([0x0A])
            try input.write(contentsOf: payload)
        } catch {
            logger.error("Failed to write app-server notification")
        }
    }

    private func consumeStdout(_ data: Data) {
        stdoutBuffer.append(data)

        while let newline = stdoutBuffer.firstRange(of: Data([0x0A])) {
            let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newline.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline.lowerBound)

            guard !line.isEmpty else { continue }
            handleLine(line)
        }
    }

    private func handleLine(_ data: Data) {
        guard let header = try? decoder.decode(IncomingHeader.self, from: data) else {
            logger.error("Ignored malformed app-server message")
            return
        }

        if let id = header.id, let request = pending.removeValue(forKey: id) {
            request.timeout.cancel()
            request.completion(.success(data))
            return
        }

        if header.method == "account/rateLimits/updated" {
            DispatchQueue.main.async { [weak self] in
                self?.onRateLimitsUpdated?()
            }
        }
    }

    private func handleTermination(status: Int32) {
        let wasIntentional = stoppingIntentionally
        initialized = false

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        let error = AppServerClientError.processExited(status)
        pending.values.forEach {
            $0.timeout.cancel()
            $0.completion(.failure(error))
        }
        pending.removeAll()

        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil

        if !wasIntentional {
            DispatchQueue.main.async { [weak self] in
                self?.onUnexpectedTermination?(error)
            }
        }
    }
}
