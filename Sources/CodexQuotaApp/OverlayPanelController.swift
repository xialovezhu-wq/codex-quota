import AppKit
import SwiftUI

@MainActor
final class OverlayPanelController: NSObject, NSWindowDelegate {
    private let panel: QuietPanel
    private let stateStore: WindowStateStore

    init(state: QuotaAppState, stateStore: WindowStateStore = WindowStateStore()) {
        self.stateStore = stateStore
        let frame = stateStore.restoreFrame()
        panel = QuietPanel(
            contentRect: frame,
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.delegate = self
        panel.title = "Codex 余量"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.minSize = NSSize(width: 168, height: 56)
        panel.maxSize = NSSize(width: 420, height: 144)
        panel.level = state.isAlwaysOnTop ? .floating : .normal

        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        if #available(macOS 26.0, *) {
            behavior.insert(.canJoinAllApplications)
        }
        panel.collectionBehavior = behavior
        panel.contentView = NSHostingView(
            rootView: QuotaView()
                .environmentObject(state)
                .ignoresSafeArea()
        )
        setLocked(state.isLocked)
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func setLocked(_ locked: Bool) {
        panel.ignoresMouseEvents = locked
        panel.isMovableByWindowBackground = !locked
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        panel.level = enabled ? .floating : .normal
        panel.orderFrontRegardless()
    }

    func resetPosition() {
        stateStore.reset()
        panel.setFrame(stateStore.defaultFrame(), display: true, animate: false)
        saveFrame()
    }

    func clampToVisibleScreens() {
        let frame = stateStore.clampToVisibleScreens(panel.frame)
        panel.setFrame(frame, display: true, animate: false)
        saveFrame()
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowDidResize(_ notification: Notification) {
        saveFrame()
    }

    private func saveFrame() {
        stateStore.save(frame: panel.frame, screen: panel.screen)
    }
}

private final class QuietPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
