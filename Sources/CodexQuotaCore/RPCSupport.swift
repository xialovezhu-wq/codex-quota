import Foundation

public struct JSONLineBuffer: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
    }
}

public enum RPCRequestFactory {
    public static let allowedOutboundMethods: Set<String> = [
        "initialize",
        "initialized",
        "account/rateLimits/read"
    ]

    public static func initialize(id: Int) throws -> Data {
        try encode([
            "method": "initialize",
            "id": id,
            "params": [
                "clientInfo": [
                    "name": "codex_quota_companion",
                    "title": "Codex 余量",
                    "version": "1.0.0"
                ]
            ]
        ])
    }

    public static func initialized() throws -> Data {
        try encode([
            "method": "initialized",
            "params": [String: String]()
        ])
    }

    public static func readRateLimits(id: Int) throws -> Data {
        try encode([
            "method": "account/rateLimits/read",
            "id": id
        ])
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        guard
            let method = object["method"] as? String,
            allowedOutboundMethods.contains(method)
        else {
            throw RPCRequestError.disallowedMethod
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }
}

public enum RPCRequestError: Error {
    case disallowedMethod
}

public struct BackoffSchedule: Sendable, Equatable {
    private let delays: [TimeInterval]
    private var index = 0

    public init(delays: [TimeInterval] = [5, 15, 30, 60]) {
        self.delays = delays.isEmpty ? [60] : delays
    }

    public mutating func next() -> TimeInterval {
        let value = delays[min(index, delays.count - 1)]
        index = min(index + 1, delays.count - 1)
        return value
    }

    public mutating func reset() {
        index = 0
    }
}
