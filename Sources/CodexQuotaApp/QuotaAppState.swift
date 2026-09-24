@preconcurrency import AppKit
import Combine
import Foundation
import CodexQuotaCore

@MainActor
final class QuotaAppState: ObservableObject {
    @Published private(set) var quotaState: QuotaState = .connecting
    @Published private(set) var snapshot: QuotaSnapshot?
    @Published private(set) var claudeState: ClaudeUsageState = .connecting
    @Published private(set) var claudeSnapshot: ClaudeUsageSnapshot?
    @Published var isLocked: Bool
    @Published var isAlwaysOnTop: Bool
    @Published var opacity: Double
    @Published private(set) var isLaunchAtLoginEnabled: Bool
    @Published private(set) var eyeRestPresentation: EyeRestPresentation
    /// Today's (Beijing time) token usage from local Claude Code / Codex logs; nil until the first scan.
    @Published private(set) var todayUsage: DailyTokenUsage?
    @Published private(set) var exchangeRate: ExchangeRate

    var onLockChanged: ((Bool) -> Void)?
    var onAlwaysOnTopChanged: ((Bool) -> Void)?
    var onResetPosition: (() -> Void)?

    private let provider: QuotaProvider
    private let claudeProvider: ClaudeUsageProvider
    private let usageMonitor: TokenUsageMonitor
    private let exchangeRateProvider: ExchangeRateProvider
    private let launchAtLogin = LaunchAtLoginController()
    private let defaults: UserDefaults
    private let eyeRestController: EyeRestController
    private let eyeRestReminderPresenter = EyeRestReminderPresenter()
    private var staleTask: Task<Void, Never>?

    private enum Key {
        static let snapshot = "quota.snapshot.v1"
        static let claudeSnapshot = "claude.snapshot.v1"
        static let locked = "window.locked"
        static let alwaysOnTop = "window.alwaysOnTop"
        static let opacity = "window.opacity"
        static let eyeRestSettings = "eyeRest.settings.v1"
        /// The session the user last chose ("running"/"paused"), so a relaunch doesn't silently drop the timer.
        static let eyeRestSession = "eyeRest.session.v1"
    }

    init(
        provider: QuotaProvider = CodexAppServerProvider(),
        claudeProvider: ClaudeUsageProvider = ClaudeUsageProvider(),
        usageMonitor: TokenUsageMonitor = TokenUsageMonitor(),
        defaults: UserDefaults = .standard,
        eyeRestClock: any EyeRestClock = SystemEyeRestClock()
    ) {
        let eyeRestSettings = Self.loadEyeRestSettings(from: defaults) ?? EyeRestSettings()
        let eyeRestController = EyeRestController(settings: eyeRestSettings, clock: eyeRestClock)
        self.provider = provider
        self.claudeProvider = claudeProvider
        self.usageMonitor = usageMonitor
        let exchangeRateProvider = ExchangeRateProvider(defaults: defaults)
        self.exchangeRateProvider = exchangeRateProvider
        exchangeRate = exchangeRateProvider.rate
        self.defaults = defaults
        self.eyeRestController = eyeRestController
        eyeRestPresentation = eyeRestController.presentation
        isLocked = defaults.object(forKey: Key.locked) as? Bool ?? false
        isAlwaysOnTop = defaults.object(forKey: Key.alwaysOnTop) as? Bool ?? true
        let storedOpacity = defaults.object(forKey: Key.opacity) as? Double ?? 0.92
        opacity = min(1, max(0.70, storedOpacity))
        isLaunchAtLoginEnabled = launchAtLogin.isEnabled
        snapshot = Self.loadSnapshot(from: defaults)
        if snapshot != nil {
            quotaState = .stale
            Self.persistSnapshot(snapshot, to: defaults)
        }
        claudeSnapshot = Self.loadClaudeSnapshot(from: defaults)
        if claudeSnapshot != nil {
            claudeState = .stale
        }
        Self.persistEyeRestSettings(eyeRestSettings, to: defaults)

        provider.onEvent = { [weak self] event in
            self?.handle(event)
        }
        claudeProvider.onEvent = { [weak self] event in
            self?.handle(event)
        }
        usageMonitor.onUpdate = { [weak self] usage in
            guard let self else { return }
            let current = todayUsage
            // Republish only when the totals move, not on every scan timestamp.
            if current?.day != usage.day || current?.claude != usage.claude || current?.codex != usage.codex {
                todayUsage = usage
            }
        }
        exchangeRateProvider.onUpdate = { [weak self] rate in
            self?.exchangeRate = rate
        }
        eyeRestController.onChange = { [weak self] presentation in
            self?.eyeRestPresentation = presentation
        }
        eyeRestController.onAutomaticRestPrompt = { [weak self] in
            self?.eyeRestReminderPresenter.presentAutomaticRestPrompt()
        }
        eyeRestController.onRestFinished = { [weak self] in
            self?.eyeRestReminderPresenter.presentRestFinished()
        }
    }

    deinit {
        staleTask?.cancel()
    }

    func start() {
        provider.start()
        claudeProvider.start()
        usageMonitor.start()
        exchangeRateProvider.start()
        eyeRestController.startLifecycle()
        switch defaults.string(forKey: Key.eyeRestSession) {
        case "running":
            startEyeRest()
        case "paused":
            startEyeRest()
            pauseEyeRest()
        default:
            break
        }
        staleTask?.cancel()
        staleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.updateFreshness()
            }
        }
    }

    func stop() {
        staleTask?.cancel()
        eyeRestController.stopLifecycle()
        provider.stop()
        claudeProvider.stop()
        usageMonitor.stop()
        exchangeRateProvider.stop()
    }

    func refresh() {
        quotaState = .connecting
        provider.refresh()
        claudeProvider.refresh()
        usageMonitor.scanNow()
    }

    func startEyeRest() {
        eyeRestReminderPresenter.prepareAuthorization()
        eyeRestController.startSession()
        rememberEyeRestSession()
    }

    func pauseEyeRest() {
        eyeRestController.pauseSession()
        rememberEyeRestSession()
    }

    func resumeEyeRest() {
        eyeRestController.resumeSession()
        rememberEyeRestSession()
    }

    func toggleEyeRest() {
        if eyeRestPresentation.phase == .idle {
            eyeRestReminderPresenter.prepareAuthorization()
        }
        eyeRestController.toggleSession()
        rememberEyeRestSession()
    }

    private func rememberEyeRestSession() {
        let phase = eyeRestController.presentation.phase
        switch phase {
        case .focusing, .resting:
            defaults.set("running", forKey: Key.eyeRestSession)
        case .paused:
            defaults.set("paused", forKey: Key.eyeRestSession)
        case .idle:
            defaults.removeObject(forKey: Key.eyeRestSession)
        }
    }

    func endEyeRest() {
        eyeRestController.endSession()
        rememberEyeRestSession()
    }

    func startImmediateEyeRest() {
        eyeRestReminderPresenter.prepareAuthorization()
        eyeRestController.startImmediateRest()
        rememberEyeRestSession()
    }

    func screenAwayBegan(reason: EyeRestAwayReason) {
        eyeRestController.screenAwayBegan(reason: reason)
    }

    func screenAwayEnded(reason: EyeRestAwayReason) {
        eyeRestController.screenAwayEnded(reason: reason)
    }

    func setLocked(_ locked: Bool) {
        isLocked = locked
        defaults.set(locked, forKey: Key.locked)
        onLockChanged?(locked)
    }

    func toggleLocked() {
        setLocked(!isLocked)
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        isAlwaysOnTop = enabled
        defaults.set(enabled, forKey: Key.alwaysOnTop)
        onAlwaysOnTopChanged?(enabled)
    }

    func setOpacity(_ newValue: Double) {
        opacity = min(1, max(0.70, newValue))
        defaults.set(opacity, forKey: Key.opacity)
    }

    func toggleLaunchAtLogin() {
        do {
            try launchAtLogin.setEnabled(!isLaunchAtLoginEnabled)
            isLaunchAtLoginEnabled = launchAtLogin.isEnabled
        } catch {
            isLaunchAtLoginEnabled = launchAtLogin.isEnabled
        }
    }

    func resetPosition() {
        onResetPosition?()
    }

    var displayWindow: QuotaWindow? {
        guard let snapshot, !snapshot.hasExpiredLimit() else { return nil }
        return snapshot.limitingWindow
    }

    var isDataStale: Bool {
        guard let snapshot else { return true }
        return snapshot.isStale() || quotaState == .stale || quotaState == .offline
    }

    var displayClaudeSnapshot: ClaudeUsageSnapshot? {
        claudeSnapshot?.refreshedForElapsedResets()
    }

    var isClaudeDataStale: Bool {
        guard let claudeSnapshot else { return true }
        return claudeSnapshot.isStale() || claudeState == .stale || claudeState == .offline
    }

    #if DEBUG
    /// Offline QA only: drive the view with fixed data instead of live providers.
    func qaInject(
        codex: QuotaSnapshot?,
        codexState: QuotaState,
        claude: ClaudeUsageSnapshot?,
        claudeState: ClaudeUsageState,
        eyeRest: EyeRestPresentation? = nil,
        todayUsage: DailyTokenUsage? = nil
    ) {
        snapshot = codex
        quotaState = codexState
        claudeSnapshot = claude
        self.claudeState = claudeState
        if let eyeRest { eyeRestPresentation = eyeRest }
        self.todayUsage = todayUsage
        exchangeRate = .fallback
    }
    #endif

    private func handle(_ event: ClaudeProviderEvent) {
        switch event {
        case let .snapshot(newSnapshot):
            claudeSnapshot = newSnapshot
            claudeState = .live
            persistClaude(newSnapshot)
        case let .state(newState):
            // Keep showing the last numbers while reconnecting or offline, but never after sign-out.
            if claudeSnapshot != nil, newState == .offline || newState == .unsupported {
                claudeState = .stale
            } else if claudeSnapshot != nil, newState == .connecting, claudeState == .live {
                return
            } else {
                claudeState = newState
            }
        }
    }

    private func handle(_ event: ProviderEvent) {
        switch event {
        case let .snapshot(newSnapshot):
            snapshot = newSnapshot
            quotaState = .live
            persist(newSnapshot)
        case let .state(newState):
            if newState == .offline, snapshot != nil {
                quotaState = .stale
            } else {
                quotaState = newState
            }
        }
    }

    private func updateFreshness() {
        if let claudeSnapshot, claudeSnapshot.isStale(), claudeState == .live {
            claudeState = .stale
        }
        guard let snapshot else { return }
        if snapshot.hasExpiredLimit() {
            quotaState = .connecting
            provider.refresh()
        } else if snapshot.isStale(), quotaState == .live {
            quotaState = .stale
        }
    }

    private func persist(_ snapshot: QuotaSnapshot) {
        Self.persistSnapshot(snapshot, to: defaults)
    }

    private static func persistSnapshot(_ snapshot: QuotaSnapshot?, to defaults: UserDefaults) {
        guard let snapshot else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(PersistedQuotaSnapshot(snapshot: snapshot)) {
            defaults.set(data, forKey: Key.snapshot)
        }
    }

    private static func loadSnapshot(from defaults: UserDefaults) -> QuotaSnapshot? {
        guard let data = defaults.data(forKey: Key.snapshot) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let snapshot: QuotaSnapshot
        if let persisted = try? decoder.decode(PersistedQuotaSnapshot.self, from: data) {
            snapshot = persisted.snapshot
        } else if let legacy = try? decoder.decode(QuotaSnapshot.self, from: data) {
            snapshot = legacy
        } else {
            return nil
        }
        return snapshot.hasExpiredLimit() ? nil : snapshot
    }

    private func persistClaude(_ snapshot: ClaudeUsageSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(snapshot) {
            defaults.set(data, forKey: Key.claudeSnapshot)
        }
    }

    private static func loadClaudeSnapshot(from defaults: UserDefaults) -> ClaudeUsageSnapshot? {
        guard let data = defaults.data(forKey: Key.claudeSnapshot) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(ClaudeUsageSnapshot.self, from: data)
    }

    private static func persistEyeRestSettings(_ settings: EyeRestSettings, to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Key.eyeRestSettings)
        }
    }

    private static func loadEyeRestSettings(from defaults: UserDefaults) -> EyeRestSettings? {
        guard let data = defaults.data(forKey: Key.eyeRestSettings) else { return nil }
        return try? JSONDecoder().decode(EyeRestSettings.self, from: data)
    }
}

private struct PersistedQuotaSnapshot: Codable {
    let windows: [PersistedQuotaWindow]
    let fetchedAt: Date

    init(snapshot: QuotaSnapshot) {
        windows = snapshot.windows.map(PersistedQuotaWindow.init)
        fetchedAt = snapshot.fetchedAt
    }

    var snapshot: QuotaSnapshot {
        QuotaSnapshot(
            bucketID: "codex",
            windows: windows.enumerated().map { index, window in
                QuotaWindow(
                    id: "cached-\(index)",
                    remainingPercent: window.remainingPercent,
                    durationMinutes: window.durationMinutes,
                    resetsAt: window.resetsAt
                )
            },
            fetchedAt: fetchedAt,
            sourceVersion: "cache-v1"
        )
    }
}

private struct PersistedQuotaWindow: Codable {
    let remainingPercent: Int
    let durationMinutes: Int
    let resetsAt: Date

    init(_ window: QuotaWindow) {
        remainingPercent = window.remainingPercent
        durationMinutes = window.durationMinutes
        resetsAt = window.resetsAt
    }
}
