#if DEBUG
import AppKit
import CodexQuotaCore
import SwiftUI

/// Renders the overlay in fixed states to PNGs (`CODEX_QUOTA_QA_RENDER=<dir>`), without live data or a window.
@MainActor
enum QAPreviewRenderer {
    /// Scans the real local logs twice (cold, then incremental) and prints the totals with timings.
    static func printTodayUsage() {
        let scanner = TokenUsageScanner()
        for pass in ["cold", "warm"] {
            let started = Date()
            let usage = scanner.scan()
            let elapsed = Date().timeIntervalSince(started)
            print("[\(pass)] \(usage.day) in \(String(format: "%.3f", elapsed))s")
            for (name, tally) in [("claude", usage.claude), ("codex", usage.codex)] {
                print("  \(name): requests=\(tally.requests) tokens=\(tally.totalTokens) input=\(tally.uncachedInputTokens) cacheWrite=\(tally.cacheWriteTokens) cacheRead=\(tally.cacheReadTokens) output=\(tally.outputTokens) usd=\(String(format: "%.4f", tally.usd)) unpriced=\(tally.unpricedTokens)")
            }
        }
    }

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
        let idle = EyeRestPresentation(phase: .idle, remainingSeconds: 1_200, isWarning: false, promptCount: 0)
        let weeklyOnly = QuotaSnapshot(
            bucketID: "codex",
            windows: [QuotaWindow(id: "secondary", remainingPercent: 82, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(5 * 86_400))],
            fetchedAt: now,
            sourceVersion: "qa"
        )
        var claudeToday = TokenTally()
        claudeToday.requests = 449
        claudeToday.uncachedInputTokens = 918
        claudeToday.cacheWriteTokens = 1_472_371
        claudeToday.cacheReadTokens = 173_949_266
        claudeToday.outputTokens = 519_637
        claudeToday.usd = 56.9652
        var codexToday = TokenTally()
        codexToday.requests = 84
        codexToday.uncachedInputTokens = 986_360
        codexToday.cacheReadTokens = 16_048_768
        codexToday.outputTokens = 78_376
        codexToday.usd = 15.0562
        let usage = DailyTokenUsage(day: TokenFormatting.beijingDay(for: now), claude: claudeToday, codex: codexToday, scannedAt: now)
        let resting = EyeRestPresentation(phase: .resting, remainingSeconds: 14, isWarning: false, promptCount: 1)

        let scenarios: [(String, CGSize, (QuotaAppState) -> Void)] = [
            ("default", WindowStateStore.defaultSize, { $0.qaInject(codex: codex, codexState: .live, claude: claude, claudeState: .live, todayUsage: usage) }),
            ("focusing", WindowStateStore.defaultSize, { $0.qaInject(codex: codex, codexState: .live, claude: claude, claudeState: .live, eyeRest: focusing, todayUsage: usage) }),
            ("low", WindowStateStore.defaultSize, { $0.qaInject(codex: codex, codexState: .stale, claude: lowClaude, claudeState: .live, todayUsage: usage) }),
            ("signed-out", WindowStateStore.defaultSize, { $0.qaInject(codex: codex, codexState: .live, claude: nil, claudeState: .signedOut, todayUsage: usage) }),
            ("resting", WindowStateStore.defaultSize, { $0.qaInject(codex: codex, codexState: .live, claude: claude, claudeState: .live, eyeRest: resting, todayUsage: usage) }),
            ("real-idle", WindowStateStore.defaultSize, { $0.qaInject(codex: weeklyOnly, codexState: .live, claude: nil, claudeState: .signedOut, eyeRest: idle, todayUsage: usage) }),
            ("min", WindowStateStore.minimumSize, { $0.qaInject(codex: codex, codexState: .live, claude: claude, claudeState: .live, eyeRest: focusing, todayUsage: usage) }),
            ("scanning", WindowStateStore.defaultSize, { $0.qaInject(codex: codex, codexState: .live, claude: claude, claudeState: .live, eyeRest: focusing) }),
            ("large", NSSize(width: WindowStateStore.baseSize.width * 1.5, height: WindowStateStore.baseSize.height * 1.5), { $0.qaInject(codex: codex, codexState: .live, claude: claude, claudeState: .live, eyeRest: focusing, todayUsage: usage) })
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
