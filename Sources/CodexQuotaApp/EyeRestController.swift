import CodexQuotaCore
import Foundation

struct EyeRestPresentation: Equatable {
    let phase: EyeRestPhase
    let remainingSeconds: Int
    let isWarning: Bool
    let promptCount: Int

    var isRunning: Bool {
        phase == .focusing || phase == .resting
    }
}

enum EyeRestAwayReason: Hashable {
    case screenLocked
    case systemSleep
}

@MainActor
final class EyeRestController {
    var onChange: ((EyeRestPresentation) -> Void)?
    var onAutomaticRestPrompt: (() -> Void)?
    var onRestFinished: (() -> Void)?

    private(set) var schedule: EyeRestSchedule
    private let clock: any EyeRestClock
    private var tickerTask: Task<Void, Never>?
    private var lifecycleStarted = false
    private var lastPublished: EyeRestPresentation?
    private var awayReasons: Set<EyeRestAwayReason> = []
    private var screenAwayStartedAt: TimeInterval?
    private var wasRunningBeforeAway = false

    init(
        settings: EyeRestSettings = EyeRestSettings(),
        clock: any EyeRestClock = SystemEyeRestClock()
    ) {
        schedule = EyeRestSchedule(settings: settings)
        self.clock = clock
    }

    var presentation: EyeRestPresentation {
        let now = clock.now()
        return EyeRestPresentation(
            phase: schedule.session.phase,
            remainingSeconds: Int(ceil(schedule.remaining(at: now))),
            isWarning: schedule.isWarning(at: now),
            promptCount: schedule.session.promptCount
        )
    }

    func startLifecycle() {
        guard !lifecycleStarted else { return }
        lifecycleStarted = true
        publish()
    }

    private func updateTicker() {
        let running = schedule.session.phase == .focusing || schedule.session.phase == .resting
        guard lifecycleStarted, running else {
            tickerTask?.cancel()
            tickerTask = nil
            return
        }
        guard tickerTask == nil else { return }
        tickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                let transition = self.schedule.advance(at: self.clock.now())
                self.publish()
                if transition == .restPromptShown {
                    self.onAutomaticRestPrompt?()
                } else if transition == .restFinished {
                    self.onRestFinished?()
                }
            }
        }
    }

    func stopLifecycle() {
        lifecycleStarted = false
        tickerTask?.cancel()
        tickerTask = nil
        _ = schedule.stop()
        publish()
    }

    func startSession() {
        _ = schedule.start(at: clock.now())
        publish()
    }

    func pauseSession() {
        _ = schedule.pause(at: clock.now())
        publish()
    }

    func resumeSession() {
        _ = schedule.resume(at: clock.now())
        publish()
    }

    func toggleSession() {
        _ = schedule.toggle(at: clock.now())
        publish()
    }

    func endSession() {
        _ = schedule.stop()
        publish()
    }

    func startImmediateRest() {
        _ = schedule.startImmediateRest(at: clock.now())
        publish()
    }

    func screenAwayBegan(reason: EyeRestAwayReason) {
        let inserted = awayReasons.insert(reason).inserted
        guard inserted, awayReasons.count == 1 else { return }

        let now = clock.now()
        screenAwayStartedAt = now
        wasRunningBeforeAway = schedule.session.phase == .focusing || schedule.session.phase == .resting
        if wasRunningBeforeAway {
            _ = schedule.pause(at: now)
            publish()
        }
    }

    func screenAwayEnded(reason: EyeRestAwayReason) {
        guard awayReasons.remove(reason) != nil, awayReasons.isEmpty else { return }
        guard wasRunningBeforeAway, let startedAt = screenAwayStartedAt else {
            clearAwayState()
            return
        }

        let now = clock.now()
        if now - startedAt >= schedule.settings.restDuration {
            _ = schedule.restartFocus(at: now)
        } else {
            _ = schedule.resume(at: now)
        }
        clearAwayState()
        publish()
    }

    private func clearAwayState() {
        screenAwayStartedAt = nil
        wasRunningBeforeAway = false
    }

    private func publish() {
        updateTicker()
        let value = presentation
        guard value != lastPublished else { return }
        lastPublished = value
        onChange?(value)
    }
}
