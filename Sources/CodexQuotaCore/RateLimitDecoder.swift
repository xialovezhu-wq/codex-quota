import Foundation

public enum RateLimitDecodeError: Error, Equatable, LocalizedError {
    case invalidEnvelope
    case remoteError(String)
    case missingCodexBucket
    case missingWindows

    public var errorDescription: String? {
        switch self {
        case .invalidEnvelope:
            return "额度响应格式无效"
        case let .remoteError(message):
            return message
        case .missingCodexBucket:
            return "响应中没有 Codex 主额度"
        case .missingWindows:
            return "Codex 主额度没有可用时间窗口"
        }
    }
}

public struct RateLimitDecoder {
    public static func decodeResponse(
        _ data: Data,
        now: Date = Date(),
        sourceVersion: String = "app-server-v2"
    ) throws -> QuotaSnapshot {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(RateLimitEnvelope.self, from: data) else {
            throw RateLimitDecodeError.invalidEnvelope
        }

        if let error = envelope.error {
            throw RateLimitDecodeError.remoteError(error.message)
        }
        guard let result = envelope.result else {
            throw RateLimitDecodeError.invalidEnvelope
        }

        let bucket: RateLimitBucketDTO
        if let codex = result.rateLimitsByLimitId?["codex"] {
            bucket = codex
        } else if let legacy = result.rateLimits, legacy.limitId == nil || legacy.limitId == "codex" {
            bucket = legacy
        } else {
            throw RateLimitDecodeError.missingCodexBucket
        }

        var windows: [QuotaWindow] = []
        if let primary = makeWindow(id: "primary", dto: bucket.primary) {
            windows.append(primary)
        }
        if let secondary = makeWindow(id: "secondary", dto: bucket.secondary) {
            windows.append(secondary)
        }
        guard !windows.isEmpty else {
            throw RateLimitDecodeError.missingWindows
        }

        return QuotaSnapshot(
            bucketID: bucket.limitId ?? "codex",
            windows: windows,
            fetchedAt: now,
            sourceVersion: sourceVersion
        )
    }

    private static func makeWindow(id: String, dto: RateLimitWindowDTO?) -> QuotaWindow? {
        guard
            let dto,
            let usedPercent = dto.usedPercent,
            usedPercent.isFinite,
            let durationMinutes = dto.windowDurationMins,
            durationMinutes > 0,
            let resetsAt = dto.resetsAt,
            resetsAt > 0
        else {
            return nil
        }

        let clampedUsed = min(100, max(0, usedPercent))
        let remaining = Int((100 - clampedUsed).rounded())
        return QuotaWindow(
            id: id,
            remainingPercent: remaining,
            durationMinutes: durationMinutes,
            resetsAt: Date(timeIntervalSince1970: TimeInterval(resetsAt))
        )
    }
}

private struct RateLimitEnvelope: Decodable {
    let result: RateLimitResultDTO?
    let error: RPCErrorDTO?
}

private struct RPCErrorDTO: Decodable {
    let message: String
}

private struct RateLimitResultDTO: Decodable {
    let rateLimits: RateLimitBucketDTO?
    let rateLimitsByLimitId: [String: RateLimitBucketDTO]?
}

private struct RateLimitBucketDTO: Decodable {
    let limitId: String?
    let primary: RateLimitWindowDTO?
    let secondary: RateLimitWindowDTO?
}

private struct RateLimitWindowDTO: Decodable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Int64?
}
