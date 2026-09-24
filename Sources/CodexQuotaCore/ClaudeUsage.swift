import Foundation

/// One Claude Code usage limit, normalized to "remaining" like the Codex windows.
public struct ClaudeUsageWindow: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"

        public var durationMinutes: Int {
            self == .fiveHour ? 300 : 10_080
        }

        public var label: String {
            switch self {
            case .fiveHour: return "5 小时"
            case .sevenDay: return "每周"
            case .sevenDaySonnet: return "Sonnet 每周"
            case .sevenDayOpus: return "Opus 每周"
            }
        }
    }

    public let kind: Kind
    public let remainingPercent: Int
    public let resetsAt: Date?

    public var id: String { kind.rawValue }

    public init(kind: Kind, remainingPercent: Int, resetsAt: Date?) {
        self.kind = kind
        self.remainingPercent = min(100, max(0, remainingPercent))
        self.resetsAt = resetsAt
    }
}

public struct ClaudeUsageSnapshot: Codable, Equatable, Sendable {
    public let windows: [ClaudeUsageWindow]
    public let fetchedAt: Date

    public init(windows: [ClaudeUsageWindow], fetchedAt: Date) {
        self.windows = windows
        self.fetchedAt = fetchedAt
    }

    public var limitingWindow: ClaudeUsageWindow? {
        windows.min {
            if $0.remainingPercent == $1.remainingPercent {
                return $0.kind.durationMinutes < $1.kind.durationMinutes
            }
            return $0.remainingPercent < $1.remainingPercent
        }
    }

    public func isStale(at date: Date = Date(), threshold: TimeInterval = 900) -> Bool {
        date.timeIntervalSince(fetchedAt) > threshold
    }

    /// A window whose reset time has passed is back at 100%; drop the stale number instead of showing it.
    public func refreshedForElapsedResets(at date: Date = Date()) -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            windows: windows.map { window in
                guard let resetsAt = window.resetsAt, resetsAt <= date else { return window }
                return ClaudeUsageWindow(kind: window.kind, remainingPercent: 100, resetsAt: nil)
            },
            fetchedAt: fetchedAt
        )
    }
}

public enum ClaudeUsageState: String, Codable, Equatable, Sendable {
    case connecting
    case live
    case stale
    /// No usable Claude Code login in the keychain; the user must run `claude auth login`.
    case signedOut
    case offline
    case unsupported
}

public enum ClaudeUsageDecodeError: Error, Equatable {
    case invalidPayload
    case missingWindows
}

public enum ClaudeUsageDecoder {
    public static func decode(_ data: Data, now: Date = Date()) throws -> ClaudeUsageSnapshot {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeUsageDecodeError.invalidPayload
        }

        var windows: [ClaudeUsageWindow] = []
        for kind in ClaudeUsageWindow.Kind.allCases {
            guard
                let entry = object[kind.rawValue] as? [String: Any],
                let utilization = (entry["utilization"] as? NSNumber)?.doubleValue,
                utilization.isFinite
            else { continue }
            // Model-specific weekly caps are reported as 0% with no reset when the plan has none.
            if kind != .fiveHour, kind != .sevenDay, utilization <= 0, entry["resets_at"] as? String == nil {
                continue
            }
            let used = min(100, max(0, utilization))
            windows.append(
                ClaudeUsageWindow(
                    kind: kind,
                    remainingPercent: Int((100 - used).rounded()),
                    resetsAt: (entry["resets_at"] as? String).flatMap(parseDate)
                )
            )
        }

        guard !windows.isEmpty else { throw ClaudeUsageDecodeError.missingWindows }
        return ClaudeUsageSnapshot(windows: windows, fetchedAt: now)
    }

    static func parseDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

extension QuotaFormatting {
    /// Short reset hint for tight layouts: relative inside a day ("2 小时 5 分"), weekday and time beyond it.
    public static func compactResetLabel(
        for date: Date,
        now: Date = Date(),
        locale: Locale = Locale(identifier: "zh_CN"),
        timeZone: TimeZone = .current
    ) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 60 { return "即将重置" }
        if seconds < 86_400 {
            let minutes = Int((seconds / 60).rounded(.up))
            if minutes < 60 { return "\(minutes) 分钟后" }
            let hours = minutes / 60
            let rest = minutes % 60
            return rest == 0 ? "\(hours) 小时后" : "\(hours) 小时 \(rest) 分后"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE HH:mm"
        return formatter.string(from: date)
    }
}
