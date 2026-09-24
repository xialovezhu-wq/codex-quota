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
    try expect(QuotaFormatting.compactResetLabel(for: now.addingTimeInterval(25 * 60), now: now, timeZone: utc) == "25分钟后", "reset minutes")
    try expect(QuotaFormatting.compactResetLabel(for: now.addingTimeInterval(2 * 3600 + 5 * 60), now: now, timeZone: utc) == "2小时5分后", "reset hours")
    try expect(QuotaFormatting.compactResetLabel(for: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: -3 * 86_400), timeZone: utc) == "周四 00:00", "reset weekday")
}

func approx(_ lhs: Double, _ rhs: Double) -> Bool { abs(lhs - rhs) < 1e-9 }

/// USD for (tokens, $/MTok) pairs.
func usd(_ parts: (Double, Double)...) -> Double {
    parts.reduce(0) { $0 + $1.0 * $1.1 } / 1_000_000
}

@MainActor
func runTokenUsageTests() throws {
    // Claude: Opus 5.5 with 1-hour cache writes, cache reads at 0.05x.
    let claudeLine = Data(#"{"type":"assistant","requestId":"req_1","timestamp":"2026-09-24T01:52:55.752Z","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":18754,"cache_read_input_tokens":36208,"output_tokens":170,"cache_creation":{"ephemeral_1h_input_tokens":18754,"ephemeral_5m_input_tokens":0}}}}"#.utf8)
    let claude = try ClaudeTranscriptParser.event(fromLine: claudeLine).unwrap("claude usage line parses")
    try expect(claude.key == "msg_1|req_1", "claude dedupe key is message id + request id")
    try expect(claude.cacheWriteLong == 18_754 && claude.cacheWrite == 0, "1-hour writes kept separate")
    try expect(claude.totalTokens == 2 + 18_754 + 36_208 + 170, "claude total tokens")
    let claudeUSD = try ModelPriceBook.cost(of: claude).unwrap("opus 5.5 priced")
    try expect(approx(claudeUSD, usd((2, 4), (18_754, 8), (36_208, 0.2), (170, 20))), "opus 5.5 cost")

    var fable = claude
    fable.model = "claude-fable-5-1"
    let cost1 = try ModelPriceBook.cost(of: fable).unwrap("fable priced")
    try expect(approx(cost1, usd((2, 10), (18_754, 20), (36_208, 0.25), (170, 50))), "fable 5.1 cache reads at 0.025x")
    var fast = claude
    fast.isFastMode = true
    let cost2 = try ModelPriceBook.cost(of: fast).unwrap("fast priced")
    try expect(approx(cost2, usd((2, 8), (18_754, 16), (36_208, 0.4), (170, 40))), "opus 5.5 fast mode scales cache rates")
    var dated = claude
    dated.model = "claude-sonnet-4-5-20250929"
    try expect(ModelPriceBook.claudePrice(for: dated.model)?.input == 3, "date-suffixed model id")
    dated.model = "claude-opus-9"
    try expect(ModelPriceBook.cost(of: dated) == nil, "unknown model stays unpriced")

    let unsplit = Data(#"{"type":"assistant","timestamp":"2026-09-24T02:00:00Z","uuid":"u1","message":{"model":"claude-haiku-4-5","usage":{"input_tokens":10,"cache_creation_input_tokens":100,"output_tokens":5}}}"#.utf8)
    let haiku = try ClaudeTranscriptParser.event(fromLine: unsplit).unwrap("claude line without ids")
    try expect(haiku.cacheWrite == 100 && haiku.key == "u1", "unsplit cache writes count as 5-minute; uuid fallback key")
    try expect(ClaudeTranscriptParser.event(fromLine: Data(#"{"type":"user","message":{"content":"usage assistant"}}"#.utf8)) == nil, "non-assistant lines ignored")
    try expect(ClaudeTranscriptParser.event(fromLine: Data(#"{"type":"assistant","timestamp":"2026-09-24T02:00:00Z","message":{"model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#.utf8)) == nil, "zero-usage entries ignored")

    // Codex: model from turn_context; long-context tier above 272K prompt tokens.
    var codex = CodexRolloutParser()
    _ = codex.event(fromLine: Data(#"{"timestamp":"2026-09-24T03:04:05Z","type":"session_meta","payload":{"id":"s1"}}"#.utf8))
    _ = codex.event(fromLine: Data(#"{"timestamp":"2026-09-24T03:04:06Z","type":"turn_context","payload":{"model":"gpt-6-sol"}}"#.utf8))
    let record = Data(#"{"timestamp":"2026-09-24T03:04:16.423Z","type":"token_usage_record","payload":{"response_id":"resp_1","usage":{"input_tokens":300000,"cached_input_tokens":250000,"cache_write_input_tokens":0,"output_tokens":1000,"reasoning_output_tokens":600,"total_tokens":301000}}}"#.utf8)
    let codexEvent = try codex.event(fromLine: record).unwrap("codex record parses")
    try expect(codexEvent.model == "gpt-6-sol" && codexEvent.key == "resp|resp_1", "codex model and key")
    try expect(codexEvent.uncachedInput == 50_000 && codexEvent.cacheRead == 250_000 && codexEvent.totalTokens == 301_000, "codex split matches total_tokens")
    let cost3 = try ModelPriceBook.cost(of: codexEvent).unwrap("sol priced")
    try expect(approx(cost3, usd((50_000, 4), (250_000, 0.4), (1_000, 15))), "long-context rates for >272K prompts")
    var shortPrompt = codexEvent
    shortPrompt.uncachedInput = 1_000
    shortPrompt.cacheRead = 9_000
    shortPrompt.promptTokens = 10_000
    let cost4 = try ModelPriceBook.cost(of: shortPrompt).unwrap("sol short")
    try expect(approx(cost4, usd((1_000, 2), (9_000, 0.2), (1_000, 10))), "standard rates below threshold")
    let tokenCount = Data(#"{"timestamp":"2026-09-24T03:04:16.440Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":301000},"last_token_usage":{"input_tokens":300000,"cached_input_tokens":250000,"output_tokens":1000}}}}"#.utf8)
    try expect(codex.event(fromLine: tokenCount) == nil, "token_count ignored once usage records exist")

    var legacy = CodexRolloutParser()
    _ = legacy.event(fromLine: Data(#"{"timestamp":"2026-09-24T01:00:00Z","type":"session_meta","payload":{"id":"old"}}"#.utf8))
    _ = legacy.event(fromLine: Data(#"{"timestamp":"2026-09-24T01:00:01Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}"#.utf8))
    let legacyEvent = try legacy.event(fromLine: tokenCount).unwrap("legacy token_count fallback")
    try expect(legacyEvent.key == "total|old|301000" && legacyEvent.model == "gpt-5-codex", "legacy key from running total")
    try expect(ModelPriceBook.openAIPrice(for: "gpt-5-codex")?.standard.input == 1.25, "codex variant priced")

    // Cache hit / miss split.
    var split = TokenTally()
    split.add(claude)
    try expect(split.cacheMissTokens == 2 + 18_754, "misses are uncached input plus cache writes")
    let hitRate = try split.cacheHitRate.unwrap("hit rate")
    try expect(approx(hitRate, 36_208.0 / 54_964.0), "hit rate over all input")
    try expect(TokenTally().cacheHitRate == nil, "no input, no hit rate")
    var codexSplit = TokenTally()
    codexSplit.add(codexEvent)
    try expect(codexSplit.cacheMissTokens == 50_000 && codexSplit.cacheReadTokens == 250_000, "codex misses exclude cached input")
    try expect(TokenFormatting.percent(0.99176) == "99.2%", "percent one decimal")
    try expect(TokenFormatting.percent(0.99996) == ">99.9%", "near-100% not rounded up")
    try expect(TokenFormatting.percent(1) == "100.0%", "exact 100%")

    // Formatting.
    try expect(TokenFormatting.compactTokens(8_532) == "8,532", "small token counts grouped")
    try expect(TokenFormatting.compactTokens(1_234_567) == "123.5万", "wan with one decimal")
    try expect(TokenFormatting.compactTokens(120_000) == "12万", "trailing .0 trimmed")
    try expect(TokenFormatting.compactTokens(17_113_504) == "1711万", "whole wan above 1000万")
    try expect(TokenFormatting.compactTokens(170_089_787) == "1.70亿", "yi with two decimals")
    try expect(TokenFormatting.yuan(364.4378) == "¥364.44", "yuan rounding")
    try expect(TokenFormatting.yuan(12_345.6) == "¥12,346", "large yuan grouped")
    try expect(TokenFormatting.yuan(0.004) == "<¥0.01", "tiny yuan")
    try expect(TokenFormatting.yuan(0) == "¥0", "zero yuan")

    // Exchange rate sources.
    let er = try ExchangeRate.decode(Data(#"{"result":"success","time_last_update_unix":1790208152,"rates":{"USD":1,"CNY":6.722655}}"#.utf8), source: "er").unwrap("open.er-api decodes")
    try expect(approx(er.usdToCNY, 6.722655) && er.asOf == "2026-09-24", "open.er-api rate and Beijing date")
    let frankfurter = try ExchangeRate.decode(Data(#"{"amount":1.0,"base":"USD","date":"2026-09-23","rates":{"CNY":6.7074}}"#.utf8), source: "ff").unwrap("frankfurter decodes")
    try expect(frankfurter.asOf == "2026-09-23", "frankfurter date")
    try expect(ExchangeRate.decode(Data(#"{"result":"error","rates":{"CNY":6.7}}"#.utf8), source: "x") == nil, "error payload rejected")
    try expect(ExchangeRate.decode(Data(#"{"rates":{"CNY":670}}"#.utf8), source: "x") == nil, "implausible rate rejected")

    try runScannerTests()
}

@MainActor
func runScannerTests() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("codexquota-scan-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let claudeDir = root.appendingPathComponent("claude/project")
    let codexDir = root.appendingPathComponent("codex/2026/09/24")
    try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: codexDir, withIntermediateDirectories: true)

    let now = Date()
    let day = TokenFormatting.beijingDayInterval(containing: now)
    let stamp = ISO8601DateFormatter()
    stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let today = stamp.string(from: day.start.addingTimeInterval(5))
    let yesterday = stamp.string(from: day.start.addingTimeInterval(-5))

    func claudeLine(_ id: String, _ time: String, output: Int = 100) -> String {
        #"{"type":"assistant","requestId":"r\#(id)","timestamp":"\#(time)","message":{"id":"m\#(id)","model":"claude-sonnet-5","usage":{"input_tokens":1000,"cache_read_input_tokens":0,"output_tokens":\#(output)}}}"#
    }
    // Same reply twice (one line per content block), one from yesterday, and a forked copy in a second file.
    let claudeFile = claudeDir.appendingPathComponent("a.jsonl")
    try ([claudeLine("1", today), claudeLine("1", today), claudeLine("0", yesterday)].joined(separator: "\n") + "\n")
        .write(to: claudeFile, atomically: true, encoding: .utf8)
    try (claudeLine("1", today) + "\n").write(to: claudeDir.appendingPathComponent("fork.jsonl"), atomically: true, encoding: .utf8)
    try (claudeLine("9", today) + "\n").write(to: claudeDir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

    let codexFile = codexDir.appendingPathComponent("rollout.jsonl")
    let codexLines = [
        #"{"timestamp":"\#(yesterday)","type":"turn_context","payload":{"model":"gpt-6-luna"}}"#,
        #"{"timestamp":"\#(today)","type":"token_usage_record","payload":{"response_id":"a","usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":10,"total_tokens":1010}}}"#
    ]
    try (codexLines.joined(separator: "\n") + "\n").write(to: codexFile, atomically: true, encoding: .utf8)

    let scanner = TokenUsageScanner(roots: [
        .init(source: .claude, directory: root.appendingPathComponent("claude")),
        .init(source: .codex, directory: root.appendingPathComponent("codex"))
    ], readChunkSize: 64)

    var usage = scanner.scan(now: now)
    try expect(usage.claude.requests == 1 && usage.claude.totalTokens == 1_100, "claude duplicates, forks and yesterday excluded")
    try expect(approx(usage.claude.usd, usd((1_000, 2), (100, 10))), "claude tally priced")
    try expect(usage.codex.requests == 1 && usage.codex.totalTokens == 1_010, "codex record counted with model from earlier line")
    try expect(approx(usage.codex.usd, usd((1_000, 0.1), (10, 0.5))), "codex luna priced")

    // Appends are picked up; an unfinished last line waits for its newline.
    let appender = try FileHandle(forWritingTo: claudeFile)
    try appender.seekToEnd()
    try appender.write(contentsOf: Data((claudeLine("2", today, output: 50) + "\n" + claudeLine("3", today)).utf8))
    usage = scanner.scan(now: now)
    try expect(usage.claude.requests == 2 && usage.claude.totalTokens == 1_100 + 1_050, "appended line counted, partial line deferred")
    try appender.write(contentsOf: Data("\n".utf8))
    try appender.close()
    usage = scanner.scan(now: now)
    try expect(usage.claude.requests == 3, "partial line counted once complete")
    usage = scanner.scan(now: now)
    try expect(usage.claude.requests == 3 && usage.codex.requests == 1, "rescans do not double count")

    // Next day: files last modified today are no longer today's usage.
    usage = scanner.scan(now: day.end.addingTimeInterval(60))
    try expect(usage.claude.requests == 0 && usage.codex.requests == 0 && usage.day != TokenFormatting.beijingDay(for: now), "new Beijing day starts from zero")
}

extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let value = self else { throw TestFailure.failed(message) }
        return value
    }
}

do {
    try runTests()
    try runClaudeUsageTests()
    try runTokenUsageTests()
    print("PASS: \(checks) checks")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
