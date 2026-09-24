import CodexQuotaCore
import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case let .failed(message): return message }
    }
}

var checks = 0

@MainActor
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    checks += 1
    if !condition() { throw TestFailure.failed(message) }
}

func method(in data: Data) throws -> String {
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let method = object?["method"] as? String else {
        throw TestFailure.failed("RPC missing method")
    }
    return method
}

@MainActor
func runTests() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let multi = Data(#"{"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":61.2,"windowDurationMins":300,"resetsAt":1800003600},"secondary":{"usedPercent":44,"windowDurationMins":10080,"resetsAt":1800604800}},"spark":{"limitId":"spark","primary":{"usedPercent":99,"windowDurationMins":60,"resetsAt":1800000100}}}}}"#.utf8)
    let snapshot = try RateLimitDecoder.decodeResponse(multi, now: now, sourceVersion: "test")
    try expect(snapshot.bucketID == "codex", "must prioritize codex bucket")
    try expect(snapshot.windows.map(\.remainingPercent) == [39, 56], "must decode both windows")
    try expect(snapshot.limitingWindow?.id == "primary", "must select minimum remaining window")
    try expect(snapshot.sourceVersion == "test", "source version metadata")
    try expect(QuotaFormatting.durationLabel(minutes: 300) == "5 小时", "hour window formatting")
    try expect(QuotaFormatting.durationLabel(minutes: 10_080) == "7 天", "week window formatting")
    let utc = TimeZone(secondsFromGMT: 0)!
    let resetLabel = QuotaFormatting.resetLabel(
        for: Date(timeIntervalSince1970: 0),
        now: Date(timeIntervalSince1970: 60),
        timeZone: utc
    )
    try expect(resetLabel == "00:00 重置", "timezone reset formatting")

    let legacy = Data(#"{"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":1800604800}}}}"#.utf8)
    let legacySnapshot = try RateLimitDecoder.decodeResponse(legacy, now: now)
    try expect(legacySnapshot.limitingWindow?.remainingPercent == 80, "legacy fallback")

    for (used, expected) in [(-20.0, 100), (0.0, 100), (25.4, 75), (100.0, 0), (140.0, 0)] {
        let data = Data("{\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":\(used),\"windowDurationMins\":300,\"resetsAt\":1800003600}}}}".utf8)
        let clampedSnapshot = try RateLimitDecoder.decodeResponse(data, now: now)
        try expect(clampedSnapshot.limitingWindow?.remainingPercent == expected, "clamp and round \(used)")
    }

    let unknown = Data(#"{"jsonrpc":"2.0","id":2,"result":{"unknown":{"private":"discard"},"rateLimits":{"limitId":"codex","primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":1800003600,"extra":true}}}}"#.utf8)
    let unknownSnapshot = try RateLimitDecoder.decodeResponse(unknown, now: now)
    try expect(unknownSnapshot.limitingWindow?.remainingPercent == 99, "unknown fields")

    do {
        _ = try RateLimitDecoder.decodeResponse(Data(#"{"result":{"rateLimitsByLimitId":{"spark":{}}}}"#.utf8), now: now)
        throw TestFailure.failed("missing Codex bucket must fail")
    } catch RateLimitDecodeError.missingCodexBucket {
        checks += 1
    }

    let expired = Data(#"{"result":{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1700000000}}}}"#.utf8)
    let expiredSnapshot = try RateLimitDecoder.decodeResponse(expired, now: now)
    try expect(expiredSnapshot.limitingWindow?.isExpired(at: now) == true, "expired reset")

    var lines = JSONLineBuffer()
    try expect(lines.append(Data("{\"id\":1".utf8)).isEmpty, "fragment must buffer")
    let split = lines.append(Data("}\n{\"method\":\"updated\"}\npartial".utf8))
    try expect(split.count == 2, "coalesced JSONL must split")
    try expect(String(data: lines.append(Data("-line\n".utf8))[0], encoding: .utf8) == "partial-line", "fragment must reassemble")

    let outbound = try [RPCRequestFactory.initialize(id: 1), RPCRequestFactory.initialized(), RPCRequestFactory.readRateLimits(id: 2)].map(method)
    try expect(outbound == ["initialize", "initialized", "account/rateLimits/read"], "outbound audit")
    try expect(RPCRequestFactory.allowedOutboundMethods.count == 3, "allowlist must contain exactly three methods")

    var backoff = BackoffSchedule()
    try expect((0 ... 7).map { _ in backoff.next() } == [5, 15, 30, 60, 60, 60, 60, 60], "backoff sequence")

    let defaults = EyeRestSettings()
    try expect(defaults.focusDuration == 1_200, "default focus duration")
    try expect(defaults.restDuration == 20, "default rest duration")
    try expect(defaults.warningDuration == 60, "default warning duration")
    try expect(EyeRestFormatting.countdown(seconds: 1_200) == "20:00", "focus countdown starts at twenty minutes")
    try expect(EyeRestFormatting.countdown(seconds: 1_199) == "19:59", "focus countdown includes seconds")
    try expect(EyeRestFormatting.countdown(seconds: 60) == "1:00", "focus countdown formats one minute")
    try expect(EyeRestFormatting.countdown(seconds: -1) == "0:00", "focus countdown never displays a negative value")
    let externalSettings = try JSONDecoder().decode(
        EyeRestSettings.self,
        from: Data(#"{"focusDuration":5400,"restDuration":600,"warningDuration":900}"#.utf8)
    )
    try expect(externalSettings == EyeRestSettings(), "external preferences cannot create macro breaks")

    var eyeRest = EyeRestSchedule()
    try expect(eyeRest.start(at: 100) == .focusStarted, "eye rest starts a fresh focus period")
    try expect(eyeRest.remaining(at: 100) == 1_200, "focus starts from full duration")
    try expect(eyeRest.start(at: 200) == .none, "repeated start is idempotent")
    try expect(!eyeRest.isWarning(at: 1_239), "warning stays hidden before final minute")
    try expect(eyeRest.isWarning(at: 1_240), "warning appears in final minute")
    try expect(eyeRest.advance(at: 1_300) == .restPromptShown, "focus deadline shows one rest prompt")
    try expect(eyeRest.session.phase == .resting && eyeRest.session.promptCount == 1, "prompt is recorded as shown")
    try expect(eyeRest.remaining(at: 1_300) == 20, "rest prompt starts from twenty seconds")
    try expect(eyeRest.advance(at: 1_320) == .restFinished, "rest deadline starts next focus cycle")
    try expect(eyeRest.session.phase == .focusing && eyeRest.remaining(at: 1_320) == 1_200, "next focus cycle is fresh")

    try expect(eyeRest.pause(at: 1_420) == .paused, "active focus pauses")
    let pausedRemaining = eyeRest.remaining(at: 9_999)
    try expect(pausedRemaining == 1_100, "pause preserves remaining focus time")
    try expect(eyeRest.advance(at: 99_999) == .none, "paused schedule does not advance")
    try expect(eyeRest.resume(at: 2_000) == .resumed, "paused focus resumes")
    try expect(eyeRest.remaining(at: 2_000) == pausedRemaining, "resume excludes paused time")
    try expect(eyeRest.stop() == .stopped && eyeRest.session.phase == .idle, "stop clears the session")
    try expect(eyeRest.stop() == .none, "repeated stop is idempotent")

    var immediate = EyeRestSchedule()
    try expect(immediate.startImmediateRest(at: 10) == .restPromptShown, "immediate rest shows prompt")
    try expect(immediate.session.promptCount == 1, "immediate rest records prompt shown")
    try expect(immediate.pause(at: 15) == .paused, "rest prompt can pause")
    try expect(immediate.resume(at: 100) == .resumed && immediate.session.phase == .resting, "paused rest resumes as rest")
    try expect(immediate.remaining(at: 100) == 15, "paused rest preserves remaining seconds")
    try expect(immediate.restartFocus(at: 200) == .focusStarted, "inferred time away begins a fresh focus period")
    try expect(immediate.remaining(at: 200) == 1_200, "fresh focus follows inferred time away")

    var jumped = EyeRestSchedule()
    _ = jumped.start(at: 0)
    try expect(jumped.advance(at: 20_000) == .restPromptShown, "large time jump advances only one boundary")
    try expect(jumped.session.promptCount == 1 && jumped.session.phase == .resting, "large jump does not backfill prompts")
    try expect(jumped.remaining(at: 20_000) == 20, "large jump starts a current rest deadline")

    var ninetyMinutes = EyeRestSchedule()
    _ = ninetyMinutes.start(at: 0)
    var simulatedTime: TimeInterval = 0
    while simulatedTime <= 5_400 {
        _ = ninetyMinutes.advance(at: simulatedTime)
        simulatedTime += 1
    }
    try expect(ninetyMinutes.session.promptCount == 4, "ninety minutes produces only recurring micro-rest prompts")
}

@MainActor
func runClaudeUsageTests() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let payload = Data(#"{"five_hour":{"utilization":6.4,"resets_at":"2027-01-15T12:59:59.943648+00:00"},"seven_day":{"utilization":29,"resets_at":"2027-01-20T08:00:00Z"},"seven_day_oauth_apps":null,"seven_day_opus":{"utilization":0.0,"resets_at":null},"seven_day_sonnet":{"utilization":12,"resets_at":"2027-01-20T08:00:00Z"},"extra_usage":{"is_enabled":false}}"#.utf8)
    let snapshot = try ClaudeUsageDecoder.decode(payload, now: now)
    try expect(snapshot.windows.map(\.kind) == [.fiveHour, .sevenDay, .sevenDaySonnet], "claude windows decoded in order, empty opus cap skipped")
    try expect(snapshot.windows.map(\.remainingPercent) == [94, 71, 88], "claude utilization becomes remaining")
    try expect(snapshot.limitingWindow?.kind == .sevenDay, "claude limiting window")
    try expect(snapshot.windows[0].resetsAt.map { abs($0.timeIntervalSince1970 - 1_800_017_999.943648) < 0.01 } == true, "fractional ISO date parses")
    try expect(snapshot.windows[1].resetsAt == Date(timeIntervalSince1970: 1_800_432_000), "plain ISO date parses")

    let idle = Data(#"{"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":140,"resets_at":null}}"#.utf8)
    let idleSnapshot = try ClaudeUsageDecoder.decode(idle, now: now)
    try expect(idleSnapshot.windows.map(\.remainingPercent) == [100, 0], "claude clamps and keeps unset reset")

    let elapsed = ClaudeUsageSnapshot(
        windows: [ClaudeUsageWindow(kind: .fiveHour, remainingPercent: 3, resetsAt: now.addingTimeInterval(-1))],
        fetchedAt: now.addingTimeInterval(-60)
    ).refreshedForElapsedResets(at: now)
    try expect(elapsed.windows.first?.remainingPercent == 100, "elapsed claude window resets to full")

    do {
        _ = try ClaudeUsageDecoder.decode(Data(#"{"error":{"type":"authentication_error"}}"#.utf8), now: now)
        throw TestFailure.failed("claude error payload must not decode")
    } catch ClaudeUsageDecodeError.missingWindows {
        checks += 1
    }

    let utc = TimeZone(secondsFromGMT: 0)!
    try expect(QuotaFormatting.compactResetLabel(for: now.addingTimeInterval(30), now: now, timeZone: utc) == "即将重置", "reset imminent")
    try expect(QuotaFormatting.compactResetLabel(for: now.addingTimeInterval(25 * 60), now: now, timeZone: utc) == "25 分钟后", "reset minutes")
    try expect(QuotaFormatting.compactResetLabel(for: now.addingTimeInterval(2 * 3600 + 5 * 60), now: now, timeZone: utc) == "2 小时 5 分后", "reset hours")
    try expect(QuotaFormatting.compactResetLabel(for: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: -3 * 86_400), timeZone: utc) == "周四 00:00", "reset weekday")
}

do {
    try runTests()
    try runClaudeUsageTests()
    print("PASS: \(checks) checks")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
