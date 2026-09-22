import Foundation
import CodexQuotaCore

private enum Failure: Error { case assertion(String) }

@MainActor
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure.assertion(message) }
}

private final class FixtureClock: EyeRestClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 100
    private var reads = 0

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return time
    }

    func set(_ value: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        time = value
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }
}

@MainActor
func idleAndPausedDoNotPollOrPublish() async throws {
    let clock = FixtureClock()
    let controller = EyeRestController(clock: clock)
    var publications = 0
    controller.onChange = { _ in publications += 1 }
    controller.startLifecycle()
    defer { controller.stopLifecycle() }
    let idleReads = clock.readCount
    let idlePublications = publications
    try await Task.sleep(for: .milliseconds(650))
    print("idle: reads=\(clock.readCount - idleReads), publications=\(publications - idlePublications)")
    try expect(clock.readCount == idleReads, "idle must not poll")
    try expect(publications == idlePublications, "idle must not republish")

    controller.startSession()
    controller.pauseSession()
    let pausedReads = clock.readCount
    let pausedPublications = publications
    try await Task.sleep(for: .milliseconds(650))
    print("paused: reads=\(clock.readCount - pausedReads), publications=\(publications - pausedPublications)")
    try expect(clock.readCount == pausedReads, "paused must not poll")
    try expect(publications == pausedPublications, "paused must not republish")
}

@MainActor
func unchangedFocusIsPublishedOnce() async throws {
    let clock = FixtureClock()
    let controller = EyeRestController(clock: clock)
    var values: [EyeRestPresentation] = []
    controller.onChange = { values.append($0) }
    controller.startLifecycle()
    controller.startSession()
    defer { controller.stopLifecycle() }
    let count = values.count
    try await Task.sleep(for: .milliseconds(650))
    print("unchanged focus: extra publications=\(values.count - count)")
    try expect(values.count == count, "unchanged focus must not republish")
    clock.set(101)
    try await Task.sleep(for: .milliseconds(400))
    try expect(values.last?.remainingSeconds == 1199, "running countdown must advance")
    try expect(values.count == count + 1, "changed seconds must publish once")
}

@MainActor
private func eventually(_ condition: () -> Bool, _ message: String) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
        if ContinuousClock.now >= deadline { throw Failure.assertion(message) }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
private func restBoundariesAndScreenAwayRemainCorrect() async throws {
    let clock = FixtureClock()
    let controller = EyeRestController(clock: clock)
    var prompts = 0
    var finished = 0
    controller.onAutomaticRestPrompt = { prompts += 1 }
    controller.onRestFinished = { finished += 1 }
    controller.startLifecycle()
    controller.startSession()
    defer { controller.stopLifecycle() }
    clock.set(1300)
    try await eventually({ prompts == 1 }, "focus must reach one rest prompt")
    try expect(controller.presentation.phase == .resting, "must enter rest")
    try expect(controller.presentation.remainingSeconds == 20, "rest lasts twenty seconds")
    clock.set(1320)
    try await eventually({ finished == 1 }, "rest must finish once")
    try expect(controller.presentation.remainingSeconds == 1200, "next focus is twenty minutes")
    clock.set(1420)
    controller.screenAwayBegan(reason: .screenLocked)
    try expect(controller.presentation.phase == .paused, "lock pauses the clock")
    clock.set(1425)
    controller.screenAwayEnded(reason: .screenLocked)
    try expect(controller.presentation.remainingSeconds == 1100, "short lock preserves time left")
    controller.screenAwayBegan(reason: .screenLocked)
    controller.screenAwayBegan(reason: .systemSleep)
    clock.set(1450)
    controller.screenAwayEnded(reason: .screenLocked)
    try expect(controller.presentation.phase == .paused, "nested sleep keeps the pause")
    controller.screenAwayEnded(reason: .systemSleep)
    try expect(controller.presentation.phase == .focusing, "wake resumes focus")
    try expect(controller.presentation.remainingSeconds == 1200, "long away starts fresh focus")
    try expect(prompts == 1 && finished == 1, "away events do not duplicate notifications")
}

private struct FakeServer {
    let directory: URL
    let executable: URL
    let log: URL

    init(respond: Bool, exitEarly: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("fake-server.py")
        log = directory.appendingPathComponent("calls.txt")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let logLiteral = String(data: try encoder.encode(log.path), encoding: .utf8)!
        let source = """
        #!/usr/bin/env python3
        import json, os, sys, time
        path = \(logLiteral)
        def record(value):
            with open(path, "a") as handle:
                handle.write(value + "\\n")
        record("pid:" + str(os.getpid()))
        if \(exitEarly ? "True" : "False"): sys.exit(0)
        for line in sys.stdin:
            message = json.loads(line)
            method = message["method"]
            record(method)
            if \(respond ? "True" : "False") and method == "initialize":
                print(json.dumps({"id": message["id"], "result": {"userAgent": "fixture-server"}}), flush=True)
            if method == "account/rateLimits/read":
                print(json.dumps({"id": message["id"], "result": {"rateLimits": {"limitId": "codex", "primary": {"usedPercent": 25, "windowDurationMins": 300, "resetsAt": int(time.time()) + 3600}}}}), flush=True)
        """
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    var lines: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    var launches: Int { lines.filter { $0.hasPrefix("pid:") }.count }
}

@MainActor
private func initializationTimeoutAndCancellation() async throws {
    let silent = try FakeServer(respond: false)
    let provider = CodexAppServerProvider(
        executableURL: silent.executable,
        initializationTimeout: .milliseconds(120), restartDelays: [0.02]
    )
    defer { provider.stop(); try? FileManager.default.removeItem(at: silent.directory) }
    var states: [QuotaState] = []
    provider.onEvent = { event in if case let .state(state) = event { states.append(state) } }
    provider.start()
    do {
        try await eventually({ silent.launches >= 2 }, "silent initialize must time out and retry")
    } catch {
        print("silent fixture diagnostics: launches=\(silent.launches), events=\(states.count), first=\(states.prefix(4))")
        throw error
    }
    try expect(states.contains(.offline), "initialization timeout must report offline")
    provider.stop()
    let launchesAtStop = silent.launches
    try await Task.sleep(for: .milliseconds(200))
    try expect(silent.launches == launchesAtStop, "stop cancels timeout and scheduled restart")
    try expect(silent.lines.filter { !$0.hasPrefix("pid:") }.allSatisfy { $0 == "initialize" }, "silent handshake must not reach account calls")

    let responding = try FakeServer(respond: true)
    let connected = CodexAppServerProvider(
        executableURL: responding.executable,
        initializationTimeout: .milliseconds(300), restartDelays: [0.02]
    )
    defer { connected.stop(); try? FileManager.default.removeItem(at: responding.directory) }
    var live = false
    connected.onEvent = { event in if case .snapshot = event { live = true } }
    connected.start()
    try await eventually({ live }, "responding fixture must produce a quota snapshot")
    try await Task.sleep(for: .milliseconds(400))
    try expect(responding.launches == 1, "initialize response cancels its timeout")
    try expect(responding.lines.filter { !$0.hasPrefix("pid:") } == ["initialize", "initialized", "account/rateLimits/read"], "only the three allowed methods are sent")
    connected.stop()
    print("initialization: silent timeout/retry and response/stop cancellation passed using fake processes")
}

@MainActor
private func eofDetachesReadersOnce() async throws {
    let fake = try FakeServer(respond: false, exitEarly: true)
    let provider = CodexAppServerProvider(
        executableURL: fake.executable,
        initializationTimeout: .seconds(2), restartDelays: [1]
    )
    defer { provider.stop(); try? FileManager.default.removeItem(at: fake.directory) }
    var offlineCount = 0
    provider.onEvent = { event in if case .state(.offline) = event { offlineCount += 1 } }
    provider.start()
    try await eventually({ offlineCount > 0 }, "EOF must report offline")
    try await Task.sleep(for: .milliseconds(200))
    try expect(offlineCount == 1, "EOF must detach readers and publish offline once")
    try expect(fake.launches == 1, "EOF must honor restart backoff")
}

@main
private enum LifecycleTests {
    @MainActor static func main() async throws {
        var failures = 0
        for (name, test) in [
            ("idle/paused", idleAndPausedDoNotPollOrPublish),
            ("deduplication", unchangedFocusIsPublishedOnce),
            ("rest/lock/wake", restBoundariesAndScreenAwayRemainCorrect),
            ("initialization lifecycle", initializationTimeoutAndCancellation),
            ("EOF cleanup", eofDetachesReadersOnce),
        ] {
            if let filter = CommandLine.arguments.dropFirst().first, !name.contains(filter) { continue }
            do { try await test(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        if failures > 0 { exit(1) }
    }
}
