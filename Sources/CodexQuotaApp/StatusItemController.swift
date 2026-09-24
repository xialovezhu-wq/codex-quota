import AppKit

/// Menu bar icon: the one control that still works while the overlay is locked (click-through).
/// Clicking it opens the same menu as the overlay's right-click menu, with unlock first.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let state: QuotaAppState
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(state: QuotaAppState) {
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        setLocked(state.isLocked)
    }

    func setLocked(_ locked: Bool) {
        guard let button = statusItem.button else { return }
        button.image = locked ? Self.lockedIcon : Self.quotaIcon
        button.toolTip = locked ? "Codex 余量（已锁定，点击解锁）" : "Codex 余量"
        button.setAccessibilityLabel(locked ? "Codex 余量，悬浮窗已锁定" : "Codex 余量")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        QuotaMenu.populate(menu, with: QuotaMenu.items(for: state, placement: .menuBar))
    }

    /// A small remaining-quota bar, echoing the app icon; template so it follows the menu bar's color.
    static let quotaIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let track = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 5.25, width: 15, height: 7.5), xRadius: 3.75, yRadius: 3.75)
            track.lineWidth = 1.4
            track.stroke()
            NSBezierPath(roundedRect: NSRect(x: 3.6, y: 7.35, width: 7.2, height: 3.3), xRadius: 1.65, yRadius: 1.65).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    static let lockedIcon: NSImage = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "已锁定")?
            .withSymbolConfiguration(configuration) ?? quotaIcon
        image.isTemplate = true
        return image
    }()
}
