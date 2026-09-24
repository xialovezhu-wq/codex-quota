import AppKit
import CodexQuotaCore
import SwiftUI

struct QuotaView: View {
    @EnvironmentObject private var state: QuotaAppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { proxy in
            let metrics = LayoutMetrics(containerSize: proxy.size)
            let isResting = state.eyeRestPresentation.phase == .resting
            let groups = [codexGroup, claudeGroup]

            ZStack {
                background

                Group {
                    if isResting {
                        restingContent(metrics: metrics)
                    } else if metrics.isCompact {
                        compactContent(groups: groups, metrics: metrics)
                    } else {
                        regularContent(groups: groups, metrics: metrics)
                    }
                }
                .padding(.horizontal, metrics.padding)
                .padding(.vertical, metrics.padding * (metrics.isCompact ? 0.75 : 1))
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: groups.map(\.animationKey))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: state.eyeRestPresentation.phase)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isResting ? eyeRestAccessibilityText : accessibilityText(groups: groups))
            .contextMenu { contextMenu }
        }
    }

    // MARK: - Layouts

    private func regularContent(groups: [MeterGroup], metrics: LayoutMetrics) -> some View {
        var tileMetrics = metrics
        tileMetrics.reservesFooter = eyeRestFooterText != nil
        return VStack(alignment: .leading, spacing: metrics.gap) {
            HStack(alignment: .top, spacing: metrics.gap) {
                ForEach(groups) { group in
                    MeterTile(group: group, metrics: tileMetrics, contrast: contrast)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            if let eyeRest = eyeRestFooterText {
                HStack(spacing: 5 * metrics.scale) {
                    Image(systemName: state.eyeRestPresentation.phase == .paused ? "pause.circle" : "eye")
                        .font(.system(size: 10 * metrics.scale, weight: .medium))
                    Text(eyeRest)
                        .font(.system(size: 10.5 * metrics.scale, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 4 * metrics.scale)
                .lineLimit(1)
            }
        }
    }

    private func compactContent(groups: [MeterGroup], metrics: LayoutMetrics) -> some View {
        HStack(spacing: 10 * metrics.scale) {
            VStack(alignment: .leading, spacing: metrics.showsCompactBars ? 5 : 3) {
                ForEach(groups) { group in
                    CompactMeterRow(group: group, metrics: metrics, contrast: contrast)
                }
            }
            .frame(maxHeight: .infinity)

            if let countdown = eyeRestCountdown {
                VStack(spacing: 2) {
                    Image(systemName: state.eyeRestPresentation.phase == .paused ? "pause.circle" : "eye")
                        .font(.system(size: 10 * metrics.scale, weight: .medium))
                    Text(countdown)
                        .font(.system(size: 10.5 * metrics.scale, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(Palette.secondary)
            }
        }
    }

    private func restingContent(metrics: LayoutMetrics) -> some View {
        let seconds = state.eyeRestPresentation.remainingSeconds
        return VStack(alignment: .leading, spacing: metrics.isCompact ? 4 : 8 * metrics.scale) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "eye")
                    .font(.system(size: 13 * metrics.scale, weight: .semibold))
                    .foregroundStyle(Palette.rest)
                Text("看向远处")
                    .font(.system(size: 14 * metrics.scale, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                Spacer(minLength: 4)
                (Text("\(seconds)").font(.system(size: (metrics.isCompact ? 22 : 34) * metrics.scale, weight: .semibold, design: .rounded))
                    + Text(" 秒").font(.system(size: 12 * metrics.scale, weight: .medium)))
                    .monospacedDigit()
                    .foregroundStyle(Palette.rest)
                    .contentTransition(.numericText())
            }
            if !metrics.isCompact {
                Text("约 6 米外 · 自然眨眼 · 暂时不要看手机")
                    .font(.system(size: 11 * metrics.scale))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            MeterBar(
                progress: CGFloat(seconds) / 20,
                color: Palette.rest,
                height: (contrast == .increased ? 5 : 4) * metrics.scale
            )
        }
        .frame(maxHeight: .infinity, alignment: metrics.isCompact ? .center : .top)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if reduceTransparency {
            shape
                .fill(Palette.surface.opacity(state.opacity))
                .overlay(shape.stroke(Palette.border, lineWidth: 1))
        } else {
            shape
                .fill(.ultraThinMaterial)
                .overlay(
                    shape.fill(
                        LinearGradient(
                            colors: [Palette.surface.opacity(state.opacity), Palette.base.opacity(state.opacity)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                )
                .overlay(shape.stroke(Palette.border, lineWidth: contrast == .increased ? 1.5 : 1))
                .overlay(
                    shape
                        .inset(by: 1)
                        .stroke(Palette.topLight, lineWidth: 0.5)
                        .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
                )
        }
    }

    // MARK: - Data

    private var codexGroup: MeterGroup {
        let visible = state.displayWindow != nil ? state.snapshot?.windows ?? [] : []
        let meters = visible
            .filter { !$0.isExpired() }
            .sorted { $0.durationMinutes < $1.durationMinutes }
            .map { Meter(id: $0.id, label: Self.windowLabel(minutes: $0.durationMinutes), remaining: $0.remainingPercent, resetsAt: $0.resetsAt) }
        let hero = state.displayWindow.flatMap { window in meters.first { $0.id == window.id } }

        return MeterGroup(
            id: "codex",
            name: "Codex",
            brand: Palette.codex,
            meters: meters,
            heroID: hero?.id,
            isStale: state.isDataStale,
            isUpdating: state.quotaState == .connecting,
            message: hero == nil ? codexMessage : nil,
            hint: nil
        )
    }

    private var claudeGroup: MeterGroup {
        let snapshot = state.claudeState == .signedOut ? nil : state.displayClaudeSnapshot
        let meters = (snapshot?.windows ?? []).map {
            Meter(id: $0.id, label: $0.kind.label, remaining: $0.remainingPercent, resetsAt: $0.resetsAt)
        }
        let hero = snapshot?.limitingWindow.flatMap { window in meters.first { $0.id == window.id } }
        let message: String?
        let hint: String?
        switch (hero, state.claudeState) {
        case (.some, _):
            message = nil
            hint = nil
        case (nil, .signedOut):
            message = "需要登录 Claude Code"
            hint = "终端运行 claude auth login"
        case (nil, .connecting), (nil, .live):
            message = "正在读取用量"
            hint = nil
        case (nil, .offline):
            message = "网络不可用"
            hint = nil
        case (nil, .unsupported):
            message = "暂时无法读取用量"
            hint = nil
        case (nil, .stale):
            message = "用量数据暂不可用"
            hint = nil
        }

        return MeterGroup(
            id: "claude",
            name: "Claude",
            brand: Palette.claude,
            meters: meters,
            heroID: hero?.id,
            isStale: snapshot != nil && state.isClaudeDataStale,
            isUpdating: state.claudeState == .connecting,
            message: message,
            hint: hint
        )
    }

    private var codexMessage: String {
        switch state.quotaState {
        case .connecting: return "正在连接额度服务"
        case .signedOut: return "请先在 ChatGPT 登录"
        case .offline: return "网络不可用"
        case .unsupported: return "未找到可用的 Codex 额度"
        case .stale: return "额度数据暂不可用"
        case .live: return "正在读取额度"
        }
    }

    private static func windowLabel(minutes: Int) -> String {
        minutes == 10_080 ? "每周" : QuotaFormatting.durationLabel(minutes: minutes)
    }

    private var eyeRestCountdown: String? {
        switch state.eyeRestPresentation.phase {
        case .focusing, .paused:
            return EyeRestFormatting.countdown(seconds: state.eyeRestPresentation.remainingSeconds)
        case .idle, .resting:
            return nil
        }
    }

    private var eyeRestFooterText: String? {
        guard let countdown = eyeRestCountdown else { return nil }
        return state.eyeRestPresentation.phase == .paused ? "护眼已暂停 · 剩余 \(countdown)" : "距远眺 \(countdown)"
    }

    // MARK: - Menu

    @ViewBuilder
    private var contextMenu: some View {
        switch state.eyeRestPresentation.phase {
        case .idle:
            Button("开始 20 分钟学习  ⌃⌥R") {
                state.startEyeRest()
            }
        case .paused:
            Button("继续 20 分钟计时  ⌃⌥R") {
                state.resumeEyeRest()
            }
        case .focusing, .resting:
            Button("暂停 20 分钟计时  ⌃⌥R") {
                state.pauseEyeRest()
            }
        }

        Button("立即远眺 20 秒") {
            state.startImmediateEyeRest()
        }

        Button("结束并重置") {
            state.endEyeRest()
        }
        .disabled(state.eyeRestPresentation.phase == .idle)

        Divider()

        Button("立即刷新") {
            state.refresh()
        }

        Button("打开 Claude 用量页面") {
            if let url = URL(string: "https://claude.ai/settings/usage") {
                NSWorkspace.shared.open(url)
            }
        }

        Divider()

        Button(state.isLocked ? "解锁位置  ⌃⌥Q" : "锁定并点击穿透  ⌃⌥Q") {
            state.toggleLocked()
        }

        Button(state.isAlwaysOnTop ? "取消始终置顶" : "始终置顶") {
            state.setAlwaysOnTop(!state.isAlwaysOnTop)
        }

        Menu("透明度") {
            ForEach([0.70, 0.85, 0.92, 1.0], id: \.self) { value in
                Button("\(Int(value * 100))%\(abs(state.opacity - value) < 0.01 ? "  ✓" : "")") {
                    state.setOpacity(value)
                }
            }
        }

        Button("恢复默认位置") {
            state.resetPosition()
        }

        Divider()

        Button(state.isLaunchAtLoginEnabled ? "关闭开机启动" : "开启开机启动") {
            state.toggleLaunchAtLogin()
        }

        Button("退出 Codex 余量") {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Accessibility

    private func accessibilityText(groups: [MeterGroup]) -> String {
        var parts = groups.map { group -> String in
            guard !group.meters.isEmpty else { return "\(group.name)：\(group.message ?? "")" }
            let meters = group.meters.map { meter -> String in
                let reset = meter.resetsAt.map { "，\(QuotaFormatting.resetLabel(for: $0))" } ?? ""
                return "\(meter.label)剩余 \(meter.remaining)%\(reset)"
            }
            return "\(group.name)：\(meters.joined(separator: "；"))\(group.isStale ? "，数据延迟" : "")"
        }
        switch state.eyeRestPresentation.phase {
        case .focusing:
            parts.append("距离远眺还有 \(EyeRestFormatting.countdown(seconds: state.eyeRestPresentation.remainingSeconds))")
        case .paused:
            parts.append("眼睛休息提醒已暂停，剩余 \(EyeRestFormatting.countdown(seconds: state.eyeRestPresentation.remainingSeconds))")
        case .idle, .resting:
            break
        }
        return parts.joined(separator: "。")
    }

    private var eyeRestAccessibilityText: String {
        "请看向约六米或更远处，自然眨眼，暂时不要看手机，剩余 \(state.eyeRestPresentation.remainingSeconds) 秒"
    }
}

// MARK: - View models

private struct Meter: Identifiable, Equatable {
    let id: String
    let label: String
    let remaining: Int
    let resetsAt: Date?

    var level: Level {
        if remaining < 10 { return .critical }
        if remaining < 25 { return .low }
        return .normal
    }

    enum Level { case normal, low, critical }

    var resetText: String? {
        resetsAt.map { QuotaFormatting.compactResetLabel(for: $0) }
    }
}

private struct MeterGroup: Identifiable {
    let id: String
    let name: String
    let brand: Color
    let meters: [Meter]
    let heroID: String?
    let isStale: Bool
    let isUpdating: Bool
    let message: String?
    let hint: String?

    var hero: Meter? { meters.first { $0.id == heroID } }
    var details: [Meter] { meters.filter { $0.id != heroID } }
    var animationKey: [Int] { meters.map(\.remaining) }

    func color(for meter: Meter) -> Color {
        switch meter.level {
        case .normal: return brand
        case .low: return Palette.low
        case .critical: return Palette.critical
        }
    }

    func numberColor(for meter: Meter) -> Color {
        meter.level == .normal ? Palette.primary : color(for: meter)
    }
}

// MARK: - Components

private struct MeterTile: View {
    let group: MeterGroup
    let metrics: LayoutMetrics
    let contrast: ColorSchemeContrast

    var body: some View {
        let s = metrics.scale
        VStack(alignment: .leading, spacing: 5 * s) {
            header

            VStack(alignment: .leading, spacing: 5 * s) {
                tileBody
            }
            .frame(maxHeight: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10 * s)
        .padding(.vertical, 9 * s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.tile)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Palette.tileBorder, lineWidth: contrast == .increased ? 1 : 0.5)
                )
        )
    }

    @ViewBuilder
    private var tileBody: some View {
        let s = metrics.scale
        if let hero = group.hero {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                (Text("\(hero.remaining)").font(.system(size: 27 * s, weight: .semibold, design: .rounded))
                    + Text("%").font(.system(size: 13 * s, weight: .medium, design: .rounded)))
                    .foregroundStyle(group.numberColor(for: hero))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .opacity(group.isStale ? 0.62 : 1)
                Spacer(minLength: 2)
                if let reset = hero.resetText {
                    Text(reset)
                        .font(.system(size: 10 * s, weight: .regular, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }

            MeterBar(
                progress: CGFloat(hero.remaining) / 100,
                color: group.color(for: hero),
                height: (contrast == .increased ? 5 : 4) * s
            )
            .opacity(group.isStale ? 0.55 : 1)

            ForEach(group.details.prefix(metrics.detailRows)) { meter in
                detailRow(meter)
            }
        } else {
            Text(group.message ?? "")
                .font(.system(size: 11 * s, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            if let hint = group.hint {
                Text(hint)
                    .font(.system(size: 9.5 * s, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .textSelection(.enabled)
            }
        }
    }

    private var header: some View {
        let s = metrics.scale
        return HStack(spacing: 5 * s) {
            Circle()
                .fill(group.brand)
                .frame(width: 6 * s, height: 6 * s)
            Text(group.name)
                .font(.system(size: 11 * s, weight: .semibold))
                .foregroundStyle(Palette.primary.opacity(0.88))
            Spacer(minLength: 2)
            if group.isStale {
                Text(group.isUpdating ? "更新中" : "数据延迟")
                    .font(.system(size: 9 * s, weight: .medium))
                    .foregroundStyle(Palette.tertiary)
            } else if let hero = group.hero {
                Text(hero.label)
                    .font(.system(size: 10 * s, weight: .medium))
                    .foregroundStyle(Palette.secondary)
            }
        }
        .lineLimit(1)
    }

    private func detailRow(_ meter: Meter) -> some View {
        let s = metrics.scale
        return HStack(spacing: 6 * s) {
            Text(meter.label)
                .font(.system(size: 10 * s, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
            MeterBar(progress: CGFloat(meter.remaining) / 100, color: group.color(for: meter).opacity(0.8), height: 3 * s)
                .frame(minWidth: 12)
            Text("\(meter.remaining)%")
                .font(.system(size: 10.5 * s, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(group.numberColor(for: meter).opacity(0.9))
                .fixedSize()
        }
        .padding(.top, 2 * s)
        .help(meter.resetsAt.map { QuotaFormatting.resetLabel(for: $0) } ?? "")
        .opacity(group.isStale ? 0.62 : 1)
    }
}

private struct CompactMeterRow: View {
    let group: MeterGroup
    let metrics: LayoutMetrics
    let contrast: ColorSchemeContrast

    var body: some View {
        let s = metrics.scale
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5 * s) {
                Circle()
                    .fill(group.brand)
                    .frame(width: 5 * s, height: 5 * s)
                Text(group.name)
                    .font(.system(size: 11 * s, weight: .semibold))
                    .foregroundStyle(Palette.primary.opacity(0.88))
                if let hero = group.hero {
                    Text(hero.label)
                        .font(.system(size: 10 * s))
                        .foregroundStyle(Palette.secondary)
                    Spacer(minLength: 2)
                    Text("\(hero.remaining)%")
                        .font(.system(size: 13 * s, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(group.numberColor(for: hero))
                        .opacity(group.isStale ? 0.62 : 1)
                } else {
                    Spacer(minLength: 2)
                    Text(group.hint ?? group.message ?? "")
                        .font(.system(size: 10 * s))
                        .foregroundStyle(Palette.secondary)
                        .minimumScaleFactor(0.7)
                }
            }
            .lineLimit(1)

            if metrics.showsCompactBars, let hero = group.hero {
                MeterBar(progress: CGFloat(hero.remaining) / 100, color: group.color(for: hero), height: 3 * s)
                    .opacity(group.isStale ? 0.55 : 1)
            }
        }
    }
}

private struct MeterBar: View {
    let progress: CGFloat
    let color: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(progress > 0 ? height : 0, proxy.size.width * min(1, max(0, progress))))
            }
        }
        .frame(height: height)
    }
}

// MARK: - Layout

private struct LayoutMetrics {
    private static let defaultSize = WindowStateStore.defaultSize
    private static let maximumSize = WindowStateStore.maximumSize

    let size: CGSize
    let scale: CGFloat
    var reservesFooter = false

    init(containerSize: CGSize) {
        size = containerSize
        let widthRatio = containerSize.width / Self.defaultSize.width
        let heightRatio = containerSize.height / Self.defaultSize.height
        let limitingRatio = min(widthRatio, heightRatio)

        if containerSize.height < 112 || containerSize.width < 260 {
            // Compact rows are sized off the old single-card proportions.
            let compactRatio = min(containerSize.width / 228, containerSize.height / 72)
            scale = max(0.9, min(1.25, compactRatio))
        } else if limitingRatio < 1 {
            scale = max(0.86, limitingRatio)
        } else {
            let widthProgress = (containerSize.width - Self.defaultSize.width)
                / (Self.maximumSize.width - Self.defaultSize.width)
            let heightProgress = (containerSize.height - Self.defaultSize.height)
                / (Self.maximumSize.height - Self.defaultSize.height)
            scale = 1 + max(0, min(1, min(widthProgress, heightProgress))) * 0.45
        }
    }

    var isCompact: Bool { size.height < 112 || size.width < 260 }
    var showsCompactBars: Bool { size.height >= 84 }
    var padding: CGFloat { 11 * scale }
    var gap: CGFloat { 7 * scale }

    /// Secondary windows (e.g. the 5-hour one under a weekly hero) shown in each tile.
    var detailRows: Int {
        let spare = size.height - 100 * scale - (reservesFooter ? 22 * scale : 0)
        guard spare > 0 else { return 0 }
        return Int(spare / (20 * scale))
    }
}

private enum Palette {
    static let base = rgb(0x15, 0x17, 0x19)
    static let surface = rgb(0x22, 0x25, 0x28)
    static let primary = rgb(0xEE, 0xED, 0xE8)
    static let secondary = rgb(0x93, 0x9A, 0x97)
    static let tertiary = rgb(0x93, 0x9A, 0x97).opacity(0.7)
    static let codex = rgb(0x7F, 0xB5, 0x9D)
    static let claude = rgb(0xD9, 0x8B, 0x6C)
    static let rest = rgb(0x8F, 0xB8, 0xD6)
    static let low = rgb(0xE2, 0xB5, 0x5E)
    static let critical = rgb(0xE5, 0x6F, 0x5E)
    static let track = Color.white.opacity(0.08)
    static let tile = Color.white.opacity(0.045)
    static let tileBorder = Color.white.opacity(0.07)
    static let border = Color.white.opacity(0.10)
    static let topLight = Color.white.opacity(0.16)

    private static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> Color {
        Color(
            red: Double(red) / 255.0,
            green: Double(green) / 255.0,
            blue: Double(blue) / 255.0
        )
    }
}
