import Foundation
import Darwin

/// A source of monotonic time used by the eye-rest scheduler.
public protocol EyeRestClock: Sendable {
    func now() -> TimeInterval
}

/// The system monotonic clock used by the application.
public struct SystemEyeRestClock: EyeRestClock, Sendable {
    public init() {}

    public func now() -> TimeInterval {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let nanoseconds = Double(mach_continuous_time())
            * Double(timebase.numer)
            / Double(timebase.denom)
        return nanoseconds / 1_000_000_000
    }
}

/// Durations used by an eye-rest schedule.
public struct EyeRestSettings: Codable, Equatable, Sendable {
    public static let defaultFocusDuration: TimeInterval = 20 * 60
    public static let defaultRestDuration: TimeInterval = 20
    public static let defaultWarningDuration: TimeInterval = 60

    public let focusDuration: TimeInterval
    public let restDuration: TimeInterval
    public let warningDuration: TimeInterval

    public init() {
        focusDuration = Self.defaultFocusDuration
        restDuration = Self.defaultRestDuration
        warningDuration = Self.defaultWarningDuration
    }

    private enum CodingKeys: String, CodingKey {
        case focusDuration
        case restDuration
        case warningDuration
    }

    public init(from decoder: Decoder) throws {
        _ = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
    }
}

public enum EyeRestPhase: String, Codable, Equatable, Sendable {
    case idle
    case focusing
    case paused
    case resting
}

public enum EyeRestFormatting {
    public static func countdown(seconds: Int) -> String {
        let safeSeconds = max(0, seconds)
        return String(format: "%d:%02d", safeSeconds / 60, safeSeconds % 60)
    }
}

public enum EyeRestTransition: Equatable, Sendable {
    case none
    case focusStarted
    case restPromptShown
    case restFinished
    case paused
    case resumed
    case stopped
}

/// The in-memory state of one eye-rest session.
///
/// Active phases use `deadline`. A paused phase clears that deadline and keeps
/// its non-negative remaining duration in `pausedRemaining`, together with the
/// phase that should be restored in `resumePhase`.
public struct EyeRestSession: Equatable, Sendable {
    public var phase: EyeRestPhase
    public var deadline: TimeInterval?
    public var pausedRemaining: TimeInterval?
    public var resumePhase: EyeRestPhase?
    public var promptCount: Int

    public init(
        phase: EyeRestPhase = .idle,
        deadline: TimeInterval? = nil,
        pausedRemaining: TimeInterval? = nil,
        resumePhase: EyeRestPhase? = nil,
        promptCount: Int = 0
    ) {
        self.phase = phase
        self.deadline = Self.normalizedOptionalTime(deadline)
        self.pausedRemaining = Self.normalizedOptionalDuration(pausedRemaining)
        self.resumePhase = resumePhase
        self.promptCount = max(0, promptCount)
    }

    private static func normalizedOptionalTime(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func normalizedOptionalDuration(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite else { return nil }
        return max(0, value)
    }
}

/// A deterministic, in-memory 20-minute focus / 20-second rest state machine.
public struct EyeRestSchedule: Equatable, Sendable {
    public let settings: EyeRestSettings
    public private(set) var session: EyeRestSession

    public init(settings: EyeRestSettings = EyeRestSettings()) {
        self.settings = settings
        self.session = EyeRestSession()
    }

    /// Starts a fresh focus interval when the schedule is idle.
    @discardableResult
    public mutating func start(at time: TimeInterval) -> EyeRestTransition {
        guard session.phase == .idle else { return .none }

        let now = Self.safeTime(time)
        session.phase = .focusing
        session.deadline = Self.addingDuration(settings.focusDuration, to: now)
        session.pausedRemaining = nil
        session.resumePhase = nil
        session.promptCount = 0
        return .focusStarted
    }

    /// Pauses focusing or resting while preserving the current phase and time left.
    @discardableResult
    public mutating func pause(at time: TimeInterval) -> EyeRestTransition {
        guard session.phase == .focusing || session.phase == .resting else {
            return .none
        }

        let remaining = remaining(at: time)
        session.resumePhase = session.phase
        session.pausedRemaining = remaining
        session.phase = .paused
        session.deadline = nil
        return .paused
    }

    /// Resumes a paused focus or rest interval without counting paused time.
    @discardableResult
    public mutating func resume(at time: TimeInterval) -> EyeRestTransition {
        guard session.phase == .paused, let resumePhase = session.resumePhase else {
            return .none
        }

        let remaining = max(0, session.pausedRemaining ?? 0)
        let now = Self.safeTime(time)
        session.phase = resumePhase
        session.deadline = Self.addingDuration(remaining, to: now)
        session.pausedRemaining = nil
        session.resumePhase = nil
        return .resumed
    }

    /// Toggles idle → focusing, active → paused, and paused → active.
    @discardableResult
    public mutating func toggle(at time: TimeInterval) -> EyeRestTransition {
        switch session.phase {
        case .idle:
            return start(at: time)
        case .focusing, .resting:
            return pause(at: time)
        case .paused:
            return resume(at: time)
        }
    }

    /// Stops the schedule and clears the current session.
    @discardableResult
    public mutating func stop() -> EyeRestTransition {
        guard session.phase != .idle else { return .none }
        session = EyeRestSession()
        return .stopped
    }

    /// Starts a complete rest interval immediately.
    @discardableResult
    public mutating func startImmediateRest(at time: TimeInterval) -> EyeRestTransition {
        let now = Self.safeTime(time)
        session.phase = .resting
        session.deadline = Self.addingDuration(settings.restDuration, to: now)
        session.pausedRemaining = nil
        session.resumePhase = nil
        session.promptCount = session.promptCount == Int.max
            ? Int.max
            : session.promptCount + 1
        return .restPromptShown
    }

    /// Starts a complete focus interval immediately, preserving prompt history.
    @discardableResult
    public mutating func restartFocus(at time: TimeInterval) -> EyeRestTransition {
        let now = Self.safeTime(time)
        session.phase = .focusing
        session.deadline = Self.addingDuration(settings.focusDuration, to: now)
        session.pausedRemaining = nil
        session.resumePhase = nil
        return .focusStarted
    }

    /// Advances at most one phase boundary for the supplied time.
    @discardableResult
    public mutating func advance(at time: TimeInterval) -> EyeRestTransition {
        guard session.phase == .focusing || session.phase == .resting,
              let deadline = session.deadline
        else {
            return .none
        }

        let now = Self.safeTime(time)
        guard now >= deadline else { return .none }

        switch session.phase {
        case .focusing:
            session.phase = .resting
            session.deadline = Self.addingDuration(settings.restDuration, to: now)
            session.pausedRemaining = nil
            session.resumePhase = nil
            session.promptCount = session.promptCount == Int.max
                ? Int.max
                : session.promptCount + 1
            return .restPromptShown

        case .resting:
            session.phase = .focusing
            session.deadline = Self.addingDuration(settings.focusDuration, to: now)
            session.pausedRemaining = nil
            session.resumePhase = nil
            return .restFinished

        case .idle, .paused:
            return .none
        }
    }

    /// Returns a non-negative remaining duration for the current phase.
    public func remaining(at time: TimeInterval) -> TimeInterval {
        switch session.phase {
        case .idle:
            return 0
        case .paused:
            return max(0, session.pausedRemaining ?? 0)
        case .focusing, .resting:
            guard let deadline = session.deadline else { return 0 }
            let value = deadline - Self.safeTime(time)
            guard value.isFinite else {
                return value.sign == .minus ? 0 : Double.greatestFiniteMagnitude
            }
            return max(0, value)
        }
    }

    /// Returns whether an active focus interval is within its warning window.
    public func isWarning(at time: TimeInterval) -> Bool {
        guard session.phase == .focusing else { return false }
        let remaining = remaining(at: time)
        return remaining > 0 && remaining <= settings.warningDuration
    }

    private static func safeTime(_ time: TimeInterval) -> TimeInterval {
        guard time.isFinite else { return 0 }
        return time
    }

    private static func addingDuration(
        _ duration: TimeInterval,
        to time: TimeInterval
    ) -> TimeInterval {
        let safeTime = safeTime(time)
        if safeTime >= Double.greatestFiniteMagnitude - duration {
            return Double.greatestFiniteMagnitude
        }
        return safeTime + duration
    }
}
