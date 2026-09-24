import Foundation

public enum UsageSource: String, Codable, Sendable {
    case claude
    case codex
}

/// One billed model request read from a local Claude Code transcript or Codex rollout.
public struct UsageEvent: Equatable, Sendable {
    public var source: UsageSource
    /// Identifies the request across files (transcripts repeat entries; forked sessions copy history).
    public var key: String
    public var timestamp: Date
    public var model: String
    /// Input billed at the full rate: neither read from nor written to the prompt cache.
    public var uncachedInput: Int64 = 0
    public var cacheRead: Int64 = 0
    /// Claude: 5-minute cache writes. Codex: cache writes.
    public var cacheWrite: Int64 = 0
    /// Claude: 1-hour cache writes.
    public var cacheWriteLong: Int64 = 0
    public var output: Int64 = 0
    public var webSearchRequests = 0
    public var isFastMode = false
    public var isUSInference = false
    /// Whole prompt size, which decides OpenAI's long-context tier.
    public var promptTokens: Int64 = 0

    public var totalTokens: Int64 {
        uncachedInput + cacheRead + cacheWrite + cacheWriteLong + output
    }

    public init(source: UsageSource, key: String, timestamp: Date, model: String) {
        self.source = source
        self.key = key
        self.timestamp = timestamp
        self.model = model
    }
}

public struct TokenTally: Codable, Equatable, Sendable {
    public var requests = 0
    public var uncachedInputTokens: Int64 = 0
    public var cacheReadTokens: Int64 = 0
    public var cacheWriteTokens: Int64 = 0
    public var outputTokens: Int64 = 0
    /// Value at API list price, excluding `unpricedTokens`.
    public var usd: Double = 0
    /// Tokens from models without a known price.
    public var unpricedTokens: Int64 = 0

    public init() {}

    public var totalTokens: Int64 {
        uncachedInputTokens + cacheReadTokens + cacheWriteTokens + outputTokens
    }

    /// Input not served from the prompt cache: full-price input plus input written to the cache.
    public var cacheMissTokens: Int64 {
        uncachedInputTokens + cacheWriteTokens
    }

    /// Share of input tokens served from the cache; nil when there was no input.
    public var cacheHitRate: Double? {
        let input = cacheReadTokens + cacheMissTokens
        return input > 0 ? Double(cacheReadTokens) / Double(input) : nil
    }

    public mutating func add(_ event: UsageEvent) {
        requests += 1
        uncachedInputTokens += event.uncachedInput
        cacheReadTokens += event.cacheRead
        cacheWriteTokens += event.cacheWrite + event.cacheWriteLong
        outputTokens += event.output
        if let usd = ModelPriceBook.cost(of: event) {
            self.usd += usd
        } else {
            unpricedTokens += event.totalTokens
        }
    }

    public static func + (lhs: TokenTally, rhs: TokenTally) -> TokenTally {
        var sum = lhs
        sum.requests += rhs.requests
        sum.uncachedInputTokens += rhs.uncachedInputTokens
        sum.cacheReadTokens += rhs.cacheReadTokens
        sum.cacheWriteTokens += rhs.cacheWriteTokens
        sum.outputTokens += rhs.outputTokens
        sum.usd += rhs.usd
        sum.unpricedTokens += rhs.unpricedTokens
        return sum
    }
}

/// Today's (Beijing time) usage per tool.
public struct DailyTokenUsage: Codable, Equatable, Sendable {
    public var day: String
    public var claude: TokenTally
    public var codex: TokenTally
    public var scannedAt: Date

    public init(day: String, claude: TokenTally = TokenTally(), codex: TokenTally = TokenTally(), scannedAt: Date) {
        self.day = day
        self.claude = claude
        self.codex = codex
        self.scannedAt = scannedAt
    }

    public var combined: TokenTally { claude + codex }
}

enum UsageTimestamp {
    static func parse(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(string, strategy: Date.ISO8601FormatStyle())
    }
}

/// Byte patterns checked before a line is JSON-decoded; most lines match none.
enum Needle {
    static let usage = Data(#""usage""#.utf8)
    static let assistant = Data(#""assistant""#.utf8)
    static let tokenUsageRecord = Data(#""token_usage_record""#.utf8)
    static let turnContext = Data(#""turn_context""#.utf8)
    static let sessionMeta = Data(#""session_meta""#.utf8)
    static let tokenCount = Data(#""token_count""#.utf8)
}

extension Data {
    func contains(_ needle: Data) -> Bool {
        range(of: needle) != nil
    }
}

private extension Dictionary where Key == String, Value == Any {
    func tokens(_ key: String) -> Int64 {
        (self[key] as? NSNumber)?.int64Value ?? 0
    }
}

/// Claude Code transcript lines (`~/.claude/projects/**/*.jsonl`). Each API reply is written once per content
/// block with identical usage, so the reply's message id + request id is the de-duplication key.
public enum ClaudeTranscriptParser {
    public static func event(fromLine line: Data) -> UsageEvent? {
        guard line.contains(Needle.usage), line.contains(Needle.assistant) else { return nil }
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            object["type"] as? String == "assistant",
            let message = object["message"] as? [String: Any],
            let usage = message["usage"] as? [String: Any],
            let stamp = object["timestamp"] as? String,
            let timestamp = UsageTimestamp.parse(stamp)
        else { return nil }

        let input = usage.tokens("input_tokens")
        let read = usage.tokens("cache_read_input_tokens")
        let writes = usage.tokens("cache_creation_input_tokens")
        var write5m: Int64 = 0
        var write1h: Int64 = 0
        if let creation = usage["cache_creation"] as? [String: Any] {
            write5m = creation.tokens("ephemeral_5m_input_tokens")
            write1h = creation.tokens("ephemeral_1h_input_tokens")
        }
        // Writes without a TTL split are the default 5-minute kind.
        write5m += max(0, writes - write5m - write1h)
        let output = usage.tokens("output_tokens")

        let ids = [message["id"] as? String, object["requestId"] as? String].compactMap { $0 }
        let key = ids.isEmpty ? (object["uuid"] as? String ?? stamp) : ids.joined(separator: "|")
        var event = UsageEvent(source: .claude, key: key, timestamp: timestamp, model: message["model"] as? String ?? "")
        event.uncachedInput = input
        event.cacheRead = read
        event.cacheWrite = write5m
        event.cacheWriteLong = write1h
        event.output = output
        event.promptTokens = input + read + write5m + write1h
        event.webSearchRequests = Int((usage["server_tool_use"] as? [String: Any])?.tokens("web_search_requests") ?? 0)
        event.isFastMode = usage["speed"] as? String == "fast"
        event.isUSInference = usage["inference_geo"] as? String == "us"
        return event.totalTokens > 0 || event.webSearchRequests > 0 ? event : nil
    }
}

/// Codex rollout lines (`~/.codex/sessions/**/rollout-*.jsonl`). Stateful per file: the model comes from the
/// latest `turn_context`. Current Codex writes one `token_usage_record` per API response; older rollouts only
/// have cumulative `token_count` events, used as a fallback for files without records.
public struct CodexRolloutParser: Sendable {
    public private(set) var model: String?
    private var sessionID: String?
    private var hasUsageRecords = false

    public init() {}

    public mutating func event(fromLine line: Data) -> UsageEvent? {
        if line.contains(Needle.tokenUsageRecord) {
            guard
                let object = jsonObject(line), object["type"] as? String == "token_usage_record",
                let payload = object["payload"] as? [String: Any],
                let usage = payload["usage"] as? [String: Any],
                let timestamp = timestamp(of: object)
            else { return nil }
            hasUsageRecords = true
            let key = payload["response_id"] as? String
                ?? "\(payload["turn_id"] as? String ?? sessionID ?? "")@\(object["timestamp"] as? String ?? "")"
            return makeEvent(key: "resp|\(key)", timestamp: timestamp, usage: usage)
        }
        if line.contains(Needle.turnContext) {
            if let object = jsonObject(line), object["type"] as? String == "turn_context",
               let payload = object["payload"] as? [String: Any], let model = payload["model"] as? String {
                self.model = model
            }
            return nil
        }
        if line.contains(Needle.sessionMeta) {
            if let object = jsonObject(line), object["type"] as? String == "session_meta",
               let payload = object["payload"] as? [String: Any] {
                sessionID = payload["id"] as? String ?? payload["session_id"] as? String ?? sessionID
            }
            return nil
        }
        if !hasUsageRecords, line.contains(Needle.tokenCount) {
            guard
                let object = jsonObject(line), object["type"] as? String == "event_msg",
                let payload = object["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                let info = payload["info"] as? [String: Any],
                let last = info["last_token_usage"] as? [String: Any],
                let total = info["total_token_usage"] as? [String: Any],
                let timestamp = timestamp(of: object)
            else { return nil }
            // The running total identifies the response: repeated token_count events carry the same total.
            let key = "total|\(sessionID ?? "")|\(total.tokens("total_tokens"))"
            return makeEvent(key: key, timestamp: timestamp, usage: last)
        }
        return nil
    }

    private func makeEvent(key: String, timestamp: Date, usage: [String: Any]) -> UsageEvent? {
        let input = usage.tokens("input_tokens")
        let cached = usage.tokens("cached_input_tokens")
        let writes = usage.tokens("cache_write_input_tokens")
        var event = UsageEvent(source: .codex, key: key, timestamp: timestamp, model: model ?? "")
        event.cacheRead = cached
        event.cacheWrite = writes
        event.uncachedInput = max(0, input - cached - writes)
        // Reasoning tokens are part of output_tokens (total_tokens == input + output).
        event.output = usage.tokens("output_tokens")
        event.promptTokens = input
        return event.totalTokens > 0 ? event : nil
    }

    private func jsonObject(_ line: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    private func timestamp(of object: [String: Any]) -> Date? {
        (object["timestamp"] as? String).flatMap(UsageTimestamp.parse)
    }
}

/// Totals today's usage from local logs, reading each file incrementally: a file is read from the start once,
/// then only its new complete lines. Only files modified today are opened. Not thread-safe; own it from one
/// actor or queue.
public final class TokenUsageScanner {
    public struct Root: Sendable {
        public let source: UsageSource
        public let directory: URL
        /// Only files whose path contains this component are read (e.g. Cowork's nested `.claude/projects`).
        public let requiredPathComponent: String?

        public init(source: UsageSource, directory: URL, requiredPathComponent: String? = nil) {
            self.source = source
            self.directory = directory
            self.requiredPathComponent = requiredPathComponent
        }
    }

    public static func defaultRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Root] {
        [
            Root(source: .claude, directory: home.appendingPathComponent(".claude/projects")),
            Root(source: .claude, directory: home.appendingPathComponent(".config/claude/projects")),
            Root(
                source: .claude,
                directory: home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions"),
                requiredPathComponent: "/.claude/projects/"
            ),
            Root(source: .codex, directory: home.appendingPathComponent(".codex/sessions")),
            Root(source: .codex, directory: home.appendingPathComponent(".codex/archived_sessions"))
        ]
    }

    private struct Cursor {
        var offset: UInt64 = 0
        var codex = CodexRolloutParser()
    }

    private let roots: [Root]
    private let readChunkSize: Int
    private var day: String?
    private var dayInterval = DateInterval()
    private var cursors: [String: Cursor] = [:]
    private var seenKeys: Set<String> = []
    private var claude = TokenTally()
    private var codex = TokenTally()

    public init(roots: [Root] = TokenUsageScanner.defaultRoots(), readChunkSize: Int = 4 << 20) {
        self.roots = roots
        self.readChunkSize = readChunkSize
    }

    public func scan(now: Date = Date()) -> DailyTokenUsage {
        let today = TokenFormatting.beijingDay(for: now)
        if today != day {
            // New day: start over so yesterday's totals and cursors don't leak in.
            day = today
            dayInterval = TokenFormatting.beijingDayInterval(containing: now)
            cursors.removeAll()
            seenKeys.removeAll()
            claude = TokenTally()
            codex = TokenTally()
        }

        for root in roots {
            for (path, size) in modifiedFiles(in: root) {
                read(path: path, size: size, source: root.source)
            }
        }
        return DailyTokenUsage(day: today, claude: claude, codex: codex, scannedAt: now)
    }

    private func modifiedFiles(in root: Root) -> [(String, UInt64)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root.directory,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var files: [(String, UInt64)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let path = url.path
            if let required = root.requiredPathComponent, !path.contains(required) { continue }
            guard
                let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true,
                let modified = values.contentModificationDate,
                modified >= dayInterval.start,
                let size = values.fileSize
            else { continue }
            files.append((path, UInt64(size)))
        }
        return files
    }

    private func read(path: String, size: UInt64, source: UsageSource) {
        var cursor = cursors[path] ?? Cursor()
        if size < cursor.offset {
            // Truncated or replaced: reread; already-counted requests are skipped by key.
            cursor = Cursor()
        }
        guard size > cursor.offset, let file = FileHandle(forReadingAtPath: path) else {
            cursors[path] = cursor
            return
        }
        defer { try? file.close() }

        do {
            try file.seek(toOffset: cursor.offset)
            var pending = Data()
            while let chunk = try file.read(upToCount: readChunkSize), !chunk.isEmpty {
                pending.append(chunk)
                var lineStart = pending.startIndex
                while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
                    consume(line: pending[lineStart..<newline], source: source, cursor: &cursor)
                    lineStart = pending.index(after: newline)
                }
                cursor.offset += UInt64(lineStart - pending.startIndex)
                // Keep the unfinished last line; it's read again once it ends with a newline.
                pending = Data(pending[lineStart...])
            }
        } catch {
            // Keep whatever was read; the next scan resumes from the cursor.
        }
        cursors[path] = cursor
    }

    private func consume(line: Data, source: UsageSource, cursor: inout Cursor) {
        guard !line.isEmpty else { return }
        let event: UsageEvent?
        switch source {
        case .claude:
            event = ClaudeTranscriptParser.event(fromLine: line)
        case .codex:
            // Every line goes through the parser so it tracks the current model, even before today.
            event = cursor.codex.event(fromLine: line)
        }
        guard
            let event,
            dayInterval.contains(event.timestamp), event.timestamp < dayInterval.end,
            seenKeys.insert("\(source.rawValue)|\(event.key)").inserted
        else { return }

        switch source {
        case .claude: claude.add(event)
        case .codex: codex.add(event)
        }
    }
}
