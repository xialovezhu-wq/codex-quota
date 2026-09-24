@preconcurrency import Foundation
import CodexQuotaCore

enum ClaudeProviderEvent {
    case snapshot(ClaudeUsageSnapshot)
    case state(ClaudeUsageState)
}

/// Reads Claude Code's plan usage (5-hour and weekly limits) with the login Claude Code already keeps
/// in the macOS keychain. It only touches the keychain through `/usr/bin/security`, exactly like
/// Claude Code does, and when the access token has expired it refreshes it and writes the rotated
/// tokens back so the `claude` CLI keeps working.
@MainActor
final class ClaudeUsageProvider {
    var onEvent: ((ClaudeProviderEvent) -> Void)?

    private let pollInterval: Duration
    private let minimumRefreshSpacing: TimeInterval
    private var pollTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private var lastAttempt: Date?

    init(pollInterval: Duration = .seconds(300), minimumRefreshSpacing: TimeInterval = 30) {
        self.pollInterval = pollInterval
        self.minimumRefreshSpacing = minimumRefreshSpacing
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.fetch()
                guard let interval = self?.pollInterval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        fetchTask?.cancel()
        fetchTask = nil
    }

    func refresh() {
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < minimumRefreshSpacing { return }
        fetch()
    }

    private func fetch() {
        guard fetchTask == nil else { return }
        lastAttempt = Date()
        onEvent?(.state(.connecting))
        fetchTask = Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .utility) {
                await ClaudeUsageClient().fetch()
            }.value
            guard let self, !Task.isCancelled else { return }
            self.fetchTask = nil
            switch outcome {
            case let .snapshot(snapshot):
                self.onEvent?(.snapshot(snapshot))
            case let .state(state):
                self.onEvent?(.state(state))
            }
        }
    }
}

private struct ClaudeUsageClient: Sendable {
    private static let keychainService = "Claude Code-credentials"
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let defaultScopes = [
        "user:profile", "user:inference", "user:sessions:claude_code", "user:mcp_servers", "user:file_upload"
    ]
    /// Refresh a little before expiry so a request never races the deadline.
    private static let expiryMargin: TimeInterval = 300

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func fetch() async -> ClaudeProviderEvent {
        guard var credentials = Keychain.read() else { return .state(.signedOut) }

        if credentials.expiresAt.timeIntervalSinceNow < Self.expiryMargin {
            switch await refresh(&credentials) {
            case .ok: break
            case let .failed(state): return .state(state)
            }
        }

        switch await requestUsage(accessToken: credentials.accessToken) {
        case let .ok(snapshot):
            return .snapshot(snapshot)
        case .unauthorized:
            // The stored expiry can be wrong (clock change, revoked token); try exactly one refresh.
            if case let .failed(state) = await refresh(&credentials) { return .state(state) }
            if case let .ok(snapshot) = await requestUsage(accessToken: credentials.accessToken) {
                return .snapshot(snapshot)
            }
            return .state(.signedOut)
        case let .failed(state):
            return .state(state)
        }
    }

    private enum RefreshResult { case ok, failed(ClaudeUsageState) }
    private enum UsageResult { case ok(ClaudeUsageSnapshot), unauthorized, failed(ClaudeUsageState) }

    private func refresh(_ credentials: inout Credentials) async -> RefreshResult {
        guard let refreshToken = credentials.refreshToken else { return .failed(.signedOut) }
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let scopes = credentials.scopes.isEmpty ? Self.defaultScopes : credentials.scopes
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
            "scope": scopes.joined(separator: " ")
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .failed(.offline)
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { return .failed(.offline) }
        if status == 400 || status == 401 || status == 403 { return .failed(.signedOut) }
        guard
            status == 200,
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = body["access_token"] as? String,
            let expiresIn = (body["expires_in"] as? NSNumber)?.doubleValue
        else {
            return .failed(.stale)
        }

        credentials.accessToken = accessToken
        credentials.expiresAt = Date().addingTimeInterval(expiresIn)
        if let rotated = body["refresh_token"] as? String {
            credentials.refreshToken = rotated
        }
        if let refreshExpiresIn = (body["refresh_token_expires_in"] as? NSNumber)?.doubleValue {
            credentials.refreshTokenExpiresAt = Date().addingTimeInterval(refreshExpiresIn)
        }
        if let scope = body["scope"] as? String, !scope.isEmpty {
            credentials.scopes = scope.split(separator: " ").map(String.init)
        }
        // The old refresh token is now spent, so the rotated one must reach the keychain or
        // Claude Code would be logged out.
        Keychain.write(credentials)
        return .ok
    }

    private func requestUsage(accessToken: String) async -> UsageResult {
        var request = URLRequest(url: Self.usageURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .failed(.offline)
        }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200:
            guard let snapshot = try? ClaudeUsageDecoder.decode(data) else { return .failed(.unsupported) }
            return .ok(snapshot)
        case 401:
            return .unauthorized
        case 403:
            return .failed(.signedOut)
        default:
            return .failed(.stale)
        }
    }
}

/// The keychain item Claude Code writes: `{"claudeAiOauth": {...}, ...}`. Unknown fields are kept
/// verbatim so writing back never drops something Claude Code relies on.
private struct Credentials: @unchecked Sendable {
    var root: [String: Any]
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var refreshTokenExpiresAt: Date?
    var scopes: [String]

    init?(json: Data) {
        guard
            let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String,
            !accessToken.isEmpty
        else { return nil }
        self.root = root
        self.accessToken = accessToken
        refreshToken = oauth["refreshToken"] as? String
        let expiresMillis = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        expiresAt = Date(timeIntervalSince1970: expiresMillis / 1000)
        refreshTokenExpiresAt = (oauth["refreshTokenExpiresAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue / 1000)
        }
        scopes = oauth["scopes"] as? [String] ?? []
    }

    func serialized() -> Data? {
        var oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = accessToken
        oauth["refreshToken"] = refreshToken
        oauth["expiresAt"] = Int64(expiresAt.timeIntervalSince1970 * 1000)
        if let refreshTokenExpiresAt {
            oauth["refreshTokenExpiresAt"] = Int64(refreshTokenExpiresAt.timeIntervalSince1970 * 1000)
        }
        oauth["scopes"] = scopes
        var updated = root
        updated["claudeAiOauth"] = oauth
        return try? JSONSerialization.data(withJSONObject: updated)
    }
}

private enum Keychain {
    private static let service = "Claude Code-credentials"
    private static let security = URL(fileURLWithPath: "/usr/bin/security")

    static func read() -> Credentials? {
        let arguments = ["find-generic-password", "-a", NSUserName(), "-w", "-s", service]
        guard
            let output = run(arguments: arguments, input: nil),
            let text = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return nil }
        return Credentials(json: Data(text.utf8))
    }

    static func write(_ credentials: Credentials) {
        guard let json = credentials.serialized() else { return }
        let hex = json.map { String(format: "%02x", $0) }.joined()
        // Same form Claude Code uses: interactive mode over stdin keeps the token out of argv.
        let command = "add-generic-password -U -a \"\(NSUserName())\" -s \"\(service)\" -X \"\(hex)\"\n"
        _ = run(arguments: ["-i"], input: Data(command.utf8))
    }

    private static func run(arguments: [String], input: Data?) -> Data? {
        let process = Process()
        process.executableURL = security
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        if let input, let inputPipe {
            inputPipe.fileHandleForWriting.write(input)
            try? inputPipe.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
