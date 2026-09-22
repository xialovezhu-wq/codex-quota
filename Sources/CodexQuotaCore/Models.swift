import Foundation

public struct QuotaWindow: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let remainingPercent: Int
    public let durationMinutes: Int
    public let resetsAt: Date

    public init(
        id: String,
        remainingPercent: Int,
        durationMinutes: Int,
        resetsAt: Date
    ) {
        self.id = id
        self.remainingPercent = min(100, max(0, remainingPercent))
        self.durationMinutes = durationMinutes
        self.resetsAt = resetsAt
    }

    public var durationLabel: String {
        QuotaFormatting.durationLabel(minutes: durationMinutes)
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        resetsAt <= date
    }
}

public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public let bucketID: String
    public let windows: [QuotaWindow]
    public let fetchedAt: Date
    public let sourceVersion: String

    public init(
        bucketID: String,
        windows: [QuotaWindow],
        fetchedAt: Date,
        sourceVersion: String
    ) {
        self.bucketID = bucketID
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.sourceVersion = sourceVersion
    }

    public var limitingWindow: QuotaWindow? {
        windows.min {
            if $0.remainingPercent == $1.remainingPercent {
                return $0.durationMinutes < $1.durationMinutes
            }
            return $0.remainingPercent < $1.remainingPercent
        }
    }

    public func isStale(at date: Date = Date(), threshold: TimeInterval = 300) -> Bool {
        date.timeIntervalSince(fetchedAt) > threshold
    }

    public func hasExpiredLimit(at date: Date = Date()) -> Bool {
        guard let limitingWindow else { return true }
        return limitingWindow.isExpired(at: date)
    }
}

public enum QuotaState: String, Codable, Equatable, Sendable {
    case connecting
    case live
    case stale
    case signedOut
    case offline
    case unsupported
}

public enum QuotaFormatting {
    public static func durationLabel(minutes: Int) -> String {
        guard minutes > 0 else { return "额度窗口" }
        if minutes % 10_080 == 0 {
            let weeks = minutes / 10_080
            return weeks == 1 ? "7 天" : "\(weeks) 周"
        }
        if minutes % 1_440 == 0 {
            return "\(minutes / 1_440) 天"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60) 小时"
        }
        return "\(minutes) 分钟"
    }

    public static func resetLabel(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = Locale(identifier: "zh_CN"),
        timeZone: TimeZone = .current
    ) -> String {
        var localCalendar = calendar
        localCalendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = localCalendar.isDate(date, inSameDayAs: now) ? "HH:mm' 重置'" : "EEE HH:mm' 重置'"
        return formatter.string(from: date)
    }
}
