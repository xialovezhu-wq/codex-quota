@preconcurrency import AppKit
import Combine
import Foundation
import CodexQuotaCore

@MainActor
final class QuotaAppState: ObservableObject {
    @Published private(set) var quotaState: QuotaState = .connecting
    @Published private(set) var snapshot: QuotaSnapshot?
    @Published var isLocked: Bool
    @Published var isAlwaysOnTop: Bool
    @Published var opacity: Double
    @Published private(set) var isLaunchAtLoginEnabled: Bool
    @Published private(set) var eyeRestPresentation: EyeRestPresentation

    var onLockChanged: ((Bool) -> Void)?
    var onAlwaysOnTopChanged: ((Bool) -> Void)?
    var onResetPosition: (() -> Void)?

    private let provider: QuotaProvider
    private let launchAtLogin = LaunchAtLoginController()
    private let defaults: UserDefaults
    private let eyeRestController: EyeRestController
    private let eyeRestReminderPresenter = EyeRestReminderPresenter()
    private var staleTask: Task<Void, Never>?

    private enum Key {
        static let snapshot = "quota.snapshot.v1"
        static let locked = "window.locked"
        static let alwaysOnTop = "window.alwaysOnTop"
        static let opacity = "window.opacity"
        static let eyeRestSettings = "eyeRest.settings.v1"
    }

    init(
        provider: QuotaProvider = CodexAppServerProvider(),
        defaults: UserDefaults = .standard,
        eyeRestClock: any EyeRestClock = SystemEyeRestClock()
    ) {
        let eyeRestSettings = Self.loadEyeRestSettings(from: defaults) ?? EyeRestSettings()
        let eyeRestController = EyeRestController(settings: eyeRestSettings, clock: eyeRestClock)
        self.provider = provider
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
        Self.persistEyeRestSettings(eyeRestSettings, to: defaults)

        provider.onEvent = { [weak self] event in
            self?.handle(event)
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
        eyeRestController.startLifecycle()
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
    }

    func refresh() {
        quotaState = .connecting
        provider.refresh()
    }

    func startEyeRest() {
        eyeRestReminderPresenter.prepareAuthorization()
        eyeRestController.startSession()
    }

    func pauseEyeRest() {
        eyeRestController.pauseSession()
    }

    func resumeEyeRest() {
        eyeRestController.resumeSession()
    }

    func toggleEyeRest() {
        if eyeRestPresentation.phase == .idle {
            eyeRestReminderPresenter.prepareAuthorization()
        }
        eyeRestController.toggleSession()
    }

    func endEyeRest() {
        eyeRestController.endSession()
    }

    func startImmediateEyeRest() {
        eyeRestReminderPresenter.prepareAuthorization()
        eyeRestController.startImmediateRest()
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
