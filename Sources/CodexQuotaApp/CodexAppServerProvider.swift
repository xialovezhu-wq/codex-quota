@preconcurrency import AppKit
@preconcurrency import Foundation
import CodexQuotaCore

@MainActor
protocol QuotaProvider: AnyObject {
    var onEvent: ((ProviderEvent) -> Void)? { get set }
    func start()
    func stop()
    func refresh()
}

enum ProviderEvent {
    case snapshot(QuotaSnapshot)
    case state(QuotaState)
}

@MainActor
final class CodexAppServerProvider: QuotaProvider {
    var onEvent: ((ProviderEvent) -> Void)?

    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var lineBuffer = JSONLineBuffer()
    private var nextRequestID = 2
    private var pendingRateRequests: Set<Int> = []
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var pollTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var notificationRefreshTask: Task<Void, Never>?
    private var initializationTimeoutTask: Task<Void, Never>?
    private var backoff: BackoffSchedule
    private let executableOverride: URL?
    private let initializationTimeout: Duration
    private var generation = 0
    private var sourceVersion = "app-server-v2"
    private var stopped = true
    private var isInitialized = false
    private let outputReadLock = NSLock()

    init(
        executableURL: URL? = nil,
        initializationTimeout: Duration = .seconds(10),
        restartDelays: [TimeInterval] = [5, 15, 30, 60]
    ) {
        executableOverride = executableURL
        self.initializationTimeout = initializationTimeout
        backoff = BackoffSchedule(delays: restartDelays)
    }

    func start() {
        guard stopped else { return }
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        restartTask?.cancel()
        pollTask?.cancel()
        notificationRefreshTask?.cancel()
        restartTask = nil
        pollTask = nil
        notificationRefreshTask = nil
        terminateCurrentProcess()
    }

    func refresh() {
        guard process?.isRunning == true, isInitialized else {
            if restartTask == nil, !stopped {
                if process?.isRunning != true {
                    launch()
                }
            }
            return
        }
        requestRateLimits()
    }

    private func launch() {
        guard !stopped else { return }
        restartTask?.cancel()
        restartTask = nil
        terminateCurrentProcess()
        onEvent?(.state(.connecting))

        guard let executableURL = locateCodexExecutable() else {
            onEvent?(.state(.unsupported))
            return
        }

        generation += 1
        let activeGeneration = generation
        isInitialized = false
        lineBuffer.reset()
        pendingRateRequests.removeAll()
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputReadLock = self.outputReadLock
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            outputReadLock.lock()
            let data = handle.availableData
            DispatchQueue.main.async { [weak self] in
                self?.consumeStdout(data, generation: activeGeneration)
            }
            outputReadLock.unlock()
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.processDidTerminate(generation: activeGeneration)
            }
        }

        self.process = process
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        inputHandle = inputPipe.fileHandleForWriting

        do {
            try process.run()
            try write(RPCRequestFactory.initialize(id: 1))
            initializationTimeoutTask = Task { @MainActor [weak self, initializationTimeout] in
                try? await Task.sleep(for: initializationTimeout)
                guard !Task.isCancelled, let self,
                      self.generation == activeGeneration,
                      !self.stopped, !self.isInitialized else { return }
                self.terminateCurrentProcess()
                self.onEvent?(.state(.offline))
                self.scheduleRestart()
            }
        } catch {
            terminateCurrentProcess()
            onEvent?(.state(.offline))
            scheduleRestart()
        }
    }

    private func locateCodexExecutable() -> URL? {
        let fileManager = FileManager.default
        if let executableOverride {
            return fileManager.isExecutableFile(atPath: executableOverride.path) ? executableOverride : nil
        }
        var candidates: [URL] = []

        #if DEBUG
        if let testPath = ProcessInfo.processInfo.environment["CODEX_QUOTA_TEST_APP_SERVER"],
           !testPath.isEmpty {
            candidates.append(URL(fileURLWithPath: testPath))
        }
        #endif

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            candidates.append(appURL.appendingPathComponent("Contents/Resources/codex"))
        }
        candidates.append(URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"))

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func consumeStdout(_ data: Data, generation activeGeneration: Int) {
        guard activeGeneration == generation else { return }
        if data.isEmpty {
            processDidTerminate(generation: activeGeneration)
            return
        }
        for line in lineBuffer.append(data) {
            consumeLine(line)
        }
    }

    private func consumeLine(_ line: Data) {
        guard let header = try? JSONDecoder().decode(RPCHeader.self, from: line) else {
            return
        }

        if header.id == 1 {
            initializationTimeoutTask?.cancel()
            initializationTimeoutTask = nil
            if header.error != nil {
                onEvent?(.state(.unsupported))
                scheduleRestart()
                return
            }
            if let initialize = try? JSONDecoder().decode(InitializeEnvelope.self, from: line),
               let userAgent = initialize.result?.userAgent {
                sourceVersion = sanitizedSourceVersion(userAgent)
            }
            do {
                try write(RPCRequestFactory.initialized())
                isInitialized = true
                requestRateLimits()
                startPolling()
            } catch {
                onEvent?(.state(.offline))
                scheduleRestart()
            }
            return
        }

        if let id = header.id, pendingRateRequests.contains(id) {
            pendingRateRequests.remove(id)
            timeoutTasks.removeValue(forKey: id)?.cancel()
            do {
                let snapshot = try RateLimitDecoder.decodeResponse(
                    line,
                    now: Date(),
                    sourceVersion: sourceVersion
                )
                backoff.reset()
                onEvent?(.snapshot(snapshot))
                onEvent?(.state(.live))
            } catch let error as RateLimitDecodeError {
                handleRateLimitError(error)
            } catch {
                onEvent?(.state(.offline))
            }
            return
        }

        if header.method == "account/rateLimits/updated" {
            notificationRefreshTask?.cancel()
            notificationRefreshTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                while !Task.isCancelled, !self.pendingRateRequests.isEmpty {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard !Task.isCancelled else { return }
                self.requestRateLimits()
            }
        }
    }

    private func handleRateLimitError(_ error: RateLimitDecodeError) {
        switch error {
        case let .remoteError(message):
            let lowered = message.lowercased()
            if lowered.contains("auth") || lowered.contains("login") || lowered.contains("401") {
                onEvent?(.state(.signedOut))
            } else {
                onEvent?(.state(.offline))
            }
        case .missingCodexBucket, .missingWindows:
            onEvent?(.state(.unsupported))
        case .invalidEnvelope:
            onEvent?(.state(.offline))
        }
    }

    private func requestRateLimits() {
        guard process?.isRunning == true, isInitialized, pendingRateRequests.isEmpty else { return }
        let requestID = nextRequestID
        nextRequestID += 1

        do {
            try write(RPCRequestFactory.readRateLimits(id: requestID))
            pendingRateRequests.insert(requestID)
            timeoutTasks[requestID] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, self.pendingRateRequests.contains(requestID) else {
                    return
                }
                self.pendingRateRequests.remove(requestID)
                self.timeoutTasks.removeValue(forKey: requestID)
                self.onEvent?(.state(.offline))
                self.scheduleRestart()
            }
        } catch {
            onEvent?(.state(.offline))
            scheduleRestart()
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.requestRateLimits()
            }
        }
    }

    private func scheduleRestart() {
        guard !stopped, restartTask == nil else { return }
        pollTask?.cancel()
        pollTask = nil
        let delay = backoff.next()
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.restartTask = nil
            self.launch()
        }
    }

    private func processDidTerminate(generation activeGeneration: Int) {
        guard activeGeneration == generation, !stopped else { return }
        // EOF and Process termination may both arrive; invalidate this generation
        // and detach readers once so EOF cannot keep queuing offline events.
        terminateCurrentProcess()
        onEvent?(.state(.offline))
        scheduleRestart()
    }

    private func terminateCurrentProcess() {
        generation += 1
        initializationTimeoutTask?.cancel()
        initializationTimeoutTask = nil
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        pendingRateRequests.removeAll()
        isInitialized = false
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        try? inputHandle?.close()
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        inputHandle = nil
        outputPipe = nil
        errorPipe = nil
    }

    private func write(_ data: Data) throws {
        guard let inputHandle else { throw ProviderFailure.noInput }
        try inputHandle.write(contentsOf: data)
    }

    private func sanitizedSourceVersion(_ userAgent: String) -> String {
        let prefix = userAgent.split(separator: " ").prefix(2).joined(separator: " ")
        return prefix.isEmpty ? "app-server-v2" : prefix
    }
}

private struct RPCHeader: Decodable {
    let id: Int?
    let method: String?
    let error: RPCHeaderError?
}

private struct RPCHeaderError: Decodable {
    let message: String?
}

private struct InitializeEnvelope: Decodable {
    struct Result: Decodable {
        let userAgent: String?
    }
    let result: Result?
}

private enum ProviderFailure: Error {
    case noInput
}
