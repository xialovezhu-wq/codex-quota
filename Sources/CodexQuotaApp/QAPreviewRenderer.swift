#if DEBUG
import AppKit
import CodexQuotaCore
import SwiftUI

/// Renders the overlay in fixed states to PNGs (`CODEX_QUOTA_QA_RENDER=<dir>`), without live data or a window.
@MainActor
enum QAPreviewRenderer {
    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let codex = QuotaSnapshot(
            bucketID: "codex",
            windows: [
                QuotaWindow(id: "primary", remainingPercent: 96, durationMinutes: 300, resetsAt: now.addingTimeInterval(3 * 3600 + 720)),
                QuotaWindow(id: "secondary", remainingPercent: 82, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(5 * 86_400))
            ],
            fetchedAt: now,
            sourceVersion: "qa"
        )
        let claude = ClaudeUsageSnapshot(
            windows: [
                ClaudeUsageWindow(kind: .fiveHour, remainingPercent: 58, resetsAt: now.addingTimeInterval(2 * 3600 + 300)),
                ClaudeUsageWindow(kind: .sevenDay, remainingPercent: 71, resetsAt: now.addingTimeInterval(3 * 86_400))
            ],
            fetchedAt: now
        )
        let lowClaude = ClaudeUsageSnapshot(
            windows: [
                ClaudeUsageWindow(kind: .fiveHour, remainingPercent: 7, resetsAt: now.addingTimeInterval(40 * 60)),
                ClaudeUsageWindow(kind: .sevenDay, remainingPercent: 22, resetsAt: now.addingTimeInterval(3 * 86_400))
            ],
            fetchedAt: now
        )
        let focusing = EyeRestPresentation(phase: .focusing, remainingSeconds: 481, isWarning: false, promptCount: 0)
        let resting = EyeRestPresentation(phase: .resting, remainingSeconds: 14, isWarning: false, promptCount: 1)

        let scenarios: [(String, CGSize, (QuotaAppState) -> Void)] = [
            ("default", WindowStateStore.defaultSize, { $0.qaInject(codex: codex, codexState: .live, claude: claude, claudeState: .live) }),
            ("focusing", WindowStateStore.defaultSize, { $0.qaInject(codex: codex, codexState: .live, claude: claude, claudeState: .live, eyeRest: focusing) }),
            ("low", WindowStateStore.defaultSize, { $0.qaInject(codex: codex, codexState: .stale, claude: lowClaude, claudeState: .live) }),
            ("signed-out", WindowStateStore.defaultSize, { $0.qaInject(codex: codex, codexState: .live, claude: nil, claudeState: .signedOut) }),
            ("resting", WindowStateStore.defaultSize, { $0.qaInject(codex: codex, codexState: .live, claude: claude, claudeState: .live, eyeRest: resting) }),
            ("compact", CGSize(width: 228, height: 72), { $0.qaInject(codex: codex, codexState: .live, claude: claude, claudeState: .live, eyeRest: focusing) }),
            ("compact-min", WindowStateStore.minimumSize, { $0.qaInject(codex: codex, codexState: .live, claude: claude, claudeState: .live) }),
            ("large", CGSize(width: 480, height: 230), { $0.qaInject(codex: codex, codexState: .live, claude: claude, claudeState: .live, eyeRest: focusing) })
        ]

        for (name, size, configure) in scenarios {
            let defaults = UserDefaults(suiteName: "codexquota.qa.\(UUID().uuidString)")!
            let state = QuotaAppState(defaults: defaults)
            configure(state)
            let view = QuotaView()
                .environmentObject(state)
                .frame(width: size.width, height: size.height)
                .padding(16)
                .background(Color(red: 0.55, green: 0.58, blue: 0.62))
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard
                let image = renderer.cgImage,
                let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { continue }
            try? data.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }
}
#endif
