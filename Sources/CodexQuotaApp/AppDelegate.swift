@preconcurrency import AppKit
@preconcurrency import Network
import Carbon
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = QuotaAppState()
    private var panelController: OverlayPanelController?
    private var lockHotKey: GlobalHotKey?
    private var eyeRestHotKey: GlobalHotKey?
    private let pathMonitor = NWPathMonitor()
    private var observerTokens: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        let panelController = OverlayPanelController(state: state)
        self.panelController = panelController
        state.onLockChanged = { [weak panelController] locked in
            panelController?.setLocked(locked)
        }
        state.onAlwaysOnTopChanged = { [weak panelController] enabled in
            panelController?.setAlwaysOnTop(enabled)
        }
        state.onResetPosition = { [weak panelController] in
            panelController?.resetPosition()
        }

        let lockHotKey = GlobalHotKey(identifier: 1, keyCode: UInt32(kVK_ANSI_Q)) { [weak state] in
            state?.toggleLocked()
        }
        lockHotKey.register()
        self.lockHotKey = lockHotKey

        let eyeRestHotKey = GlobalHotKey(identifier: 2, keyCode: UInt32(kVK_ANSI_R)) { [weak state] in
            state?.toggleEyeRest()
        }
        eyeRestHotKey.register()
        self.eyeRestHotKey = eyeRestHotKey

        installObservers()
        startNetworkMonitor()
        panelController.show()
        state.start()

        #if DEBUG
        if ProcessInfo.processInfo.environment["CODEX_QUOTA_QA_SHOW_EYE_REST"] == "1" {
            state.startImmediateEyeRest()
        } else if ProcessInfo.processInfo.environment["CODEX_QUOTA_QA_START_FOCUS"] == "1" {
            state.startEyeRest()
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.stop()
        lockHotKey?.unregister()
        eyeRestHotKey?.unregister()
        pathMonitor.cancel()
        for token in observerTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observerTokens.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak state] _ in
                Task { @MainActor in state?.screenAwayBegan(reason: .systemSleep) }
            }
        )

        observerTokens.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak state] _ in
                Task { @MainActor in
                    state?.screenAwayEnded(reason: .systemSleep)
                    state?.refresh()
                }
            }
        )

        observerTokens.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak state] _ in
                Task { @MainActor in state?.screenAwayBegan(reason: .screenLocked) }
            }
        )

        observerTokens.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak state] _ in
                Task { @MainActor in state?.screenAwayEnded(reason: .screenLocked) }
            }
        )

        observerTokens.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak panelController] _ in
                Task { @MainActor in panelController?.clampToVisibleScreens() }
            }
        )
    }

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak state] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                state?.refresh()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.xiazhibin.codexquota.network"))
    }
}

@main
enum CodexQuotaMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
