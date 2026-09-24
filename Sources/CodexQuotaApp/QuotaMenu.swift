import AppKit
import SwiftUI

/// One definition of the app's menu, rendered both as the overlay's right-click menu (SwiftUI) and as the
/// menu bar icon's menu (AppKit), so the two can't drift apart.
struct QuotaMenuItem: Identifiable {
    enum Kind {
        case action(title: String, isEnabled: Bool, isChecked: Bool, perform: @MainActor () -> Void)
        case submenu(title: String, items: [QuotaMenuItem])
        case separator
    }

    let id: String
    let kind: Kind

    static func action(
        _ id: String,
        _ title: String,
        enabled: Bool = true,
        checked: Bool = false,
        perform: @escaping @MainActor () -> Void
    ) -> QuotaMenuItem {
        QuotaMenuItem(id: id, kind: .action(title: title, isEnabled: enabled, isChecked: checked, perform: perform))
    }

    static func separator(_ id: String) -> QuotaMenuItem {
        QuotaMenuItem(id: id, kind: .separator)
    }
}

@MainActor
enum QuotaMenu {
    enum Placement {
        case overlay
        /// The menu bar icon exists mainly to get out of a locked (click-through) overlay, so lock comes first.
        case menuBar
    }

    static func items(for state: QuotaAppState, placement: Placement) -> [QuotaMenuItem] {
        let lockItem = QuotaMenuItem.action(
            "lock",
            state.isLocked ? "解锁位置  ⌃⌥Q" : "锁定并点击穿透  ⌃⌥Q"
        ) { state.toggleLocked() }

        var eyeRest: [QuotaMenuItem] = []
        switch state.eyeRestPresentation.phase {
        case .idle:
            eyeRest.append(.action("eye.start", "开始 20 分钟学习  ⌃⌥R") { state.startEyeRest() })
        case .paused:
            eyeRest.append(.action("eye.resume", "继续 20 分钟计时  ⌃⌥R") { state.resumeEyeRest() })
        case .focusing, .resting:
            eyeRest.append(.action("eye.pause", "暂停 20 分钟计时  ⌃⌥R") { state.pauseEyeRest() })
        }
        eyeRest.append(.action("eye.now", "立即远眺 20 秒") { state.startImmediateEyeRest() })
        eyeRest.append(.action("eye.end", "结束并重置", enabled: state.eyeRestPresentation.phase != .idle) {
            state.endEyeRest()
        })

        let data: [QuotaMenuItem] = [
            .action("refresh", "立即刷新") { state.refresh() },
            .action("claude.web", "打开 Claude 用量页面") {
                if let url = URL(string: "https://claude.ai/settings/usage") {
                    NSWorkspace.shared.open(url)
                }
            }
        ]

        let opacity = QuotaMenuItem(
            id: "opacity",
            kind: .submenu(
                title: "透明度",
                items: [0.70, 0.85, 0.92, 1.0].map { value in
                    .action("opacity.\(value)", "\(Int(value * 100))%", checked: abs(state.opacity - value) < 0.01) {
                        state.setOpacity(value)
                    }
                }
            )
        )
        let window: [QuotaMenuItem] = [
            .action("top", state.isAlwaysOnTop ? "取消始终置顶" : "始终置顶") {
                state.setAlwaysOnTop(!state.isAlwaysOnTop)
            },
            opacity,
            .action("reset.position", "恢复默认位置") { state.resetPosition() }
        ]

        let app: [QuotaMenuItem] = [
            .action("login", state.isLaunchAtLoginEnabled ? "关闭开机启动" : "开启开机启动") {
                state.toggleLaunchAtLogin()
            },
            .action("quit", "退出 Codex 余量") { NSApplication.shared.terminate(nil) }
        ]

        var items: [QuotaMenuItem] = []
        if placement == .menuBar {
            items.append(lockItem)
            items.append(.separator("s0"))
        }
        items += eyeRest
        items.append(.separator("s1"))
        items += data
        items.append(.separator("s2"))
        if placement == .overlay {
            items.append(lockItem)
        }
        items += window
        items.append(.separator("s3"))
        items += app
        return items
    }

    /// AppKit rendering for the menu bar icon.
    static func populate(_ menu: NSMenu, with items: [QuotaMenuItem]) {
        menu.removeAllItems()
        for item in items {
            switch item.kind {
            case .separator:
                menu.addItem(.separator())
            case let .action(title, isEnabled, isChecked, perform):
                let menuItem = ClosureMenuItem(title: title, perform: perform)
                menuItem.isEnabled = isEnabled
                menuItem.state = isChecked ? .on : .off
                menu.addItem(menuItem)
            case let .submenu(title, children):
                let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: title)
                submenu.autoenablesItems = false
                populate(submenu, with: children)
                parent.submenu = submenu
                menu.addItem(parent)
            }
        }
    }
}

/// SwiftUI rendering for the overlay's right-click menu.
struct QuotaMenuContent: View {
    let items: [QuotaMenuItem]

    var body: some View {
        ForEach(items) { item in
            switch item.kind {
            case .separator:
                Divider()
            case let .action(title, isEnabled, isChecked, perform):
                Button(isChecked ? "\(title)  ✓" : title) { perform() }
                    .disabled(!isEnabled)
            case let .submenu(title, children):
                Menu(title) { QuotaMenuContent(items: children) }
            }
        }
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let perform: @MainActor () -> Void

    init(title: String, perform: @escaping @MainActor () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func invoke() {
        // AppKit delivers menu actions on the main thread.
        let perform = self.perform
        MainActor.assumeIsolated { perform() }
    }
}
