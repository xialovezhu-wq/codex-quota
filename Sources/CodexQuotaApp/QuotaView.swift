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
            let window = state.displayWindow
            let compact = proxy.size.height < 64 || proxy.size.width < 196
            let expanded = proxy.size.height >= 108 && proxy.size.width >= 300
            let isResting = state.eyeRestPresentation.phase == .resting
            let typography = ResponsiveTypography(containerSize: proxy.size)

            ZStack {
                background

                VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(isResting ? "看向远处" : title(for: window, compact: compact))
                            .font(
                                .system(
                                    size: typography.title,
                                    weight: .medium,
                                    design: .default
                                )
                            )
                            .foregroundStyle(isResting ? Palette.primary : Palette.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .allowsTightening(true)

                        Spacer(minLength: 4)

                        Text(isResting ? "\(state.eyeRestPresentation.remainingSeconds) 秒" : percentText(for: window))
                            .font(.system(size: typography.percentage, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(isResting ? Palette.normal : accent(for: window))
                            .contentTransition(.opacity)
                    }

                    if !compact {
                        Text(isResting ? "自然眨眼 · 暂时不要看手机" : statusText(for: window))
                            .font(.system(size: typography.status, weight: .regular, design: .monospaced))
                            .foregroundStyle(isResting ? Palette.secondary : statusColor(for: window))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .allowsTightening(true)
                    }

                    if !isResting, expanded, let snapshot = state.snapshot, snapshot.windows.count > 1 {
                        HStack(spacing: 14) {
                            ForEach(snapshot.windows) { item in
                                Text("\(item.durationLabel)  \(item.remainingPercent)%")
                                    .font(.system(size: typography.detail, weight: .medium, design: .rounded))
                                    .foregroundStyle(Palette.secondary)
                            }
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .allowsTightening(true)
                    }

                    quietSeam(for: window, isResting: isResting)
                        .frame(height: contrast == .increased ? 3 : 2)
                }
                .padding(.horizontal, compact ? 11 : 13)
                .padding(.vertical, compact ? 8 : 10)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: window?.remainingPercent)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: state.eyeRestPresentation.phase)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isResting ? eyeRestAccessibilityText : accessibilityText(for: window))
            .contextMenu { contextMenu }
        }
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
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
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
                .overlay(shape.stroke(Palette.border, lineWidth: contrast == .increased ? 1.5 : 1))
                .overlay(
                    shape
                        .inset(by: 1)
                        .stroke(Palette.topLight, lineWidth: 0.5)
                        .mask(
                            LinearGradient(
                                colors: [.white, .clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                )
        }
    }

    private func quietSeam(for window: QuotaWindow?, isResting: Bool) -> some View {
        GeometryReader { proxy in
            let progress = isResting
                ? CGFloat(state.eyeRestPresentation.remainingSeconds) / 20
                : CGFloat(window?.remainingPercent ?? 0) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.secondary.opacity(0.16))
                Capsule()
                    .fill(isResting ? Palette.normal : accent(for: window))
                    .frame(width: max(0, proxy.size.width * min(1, progress)))
            }
        }
    }

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

    private func title(for window: QuotaWindow?, compact: Bool) -> String {
        let quotaTitle = window.map { "Codex · \($0.durationLabel)" } ?? "Codex"
        guard compact else { return quotaTitle }

        let countdown = EyeRestFormatting.countdown(seconds: state.eyeRestPresentation.remainingSeconds)
        switch state.eyeRestPresentation.phase {
        case .focusing:
            return "距远眺 \(countdown) · \(window?.durationLabel ?? "Codex")"
        case .paused:
            return "已暂停 \(countdown) · \(window?.durationLabel ?? "Codex")"
        case .idle, .resting:
            return quotaTitle
        }
    }

    private func percentText(for window: QuotaWindow?) -> String {
        guard let window else { return "—" }
        return "\(window.remainingPercent)%"
    }

    private func statusText(for window: QuotaWindow?) -> String {
        guard let window else {
            switch state.quotaState {
            case .connecting: return "正在连接额度服务"
            case .signedOut: return "请先在 ChatGPT 登录"
            case .offline: return "网络不可用"
            case .unsupported: return "未找到可用的 Codex 额度"
            case .stale: return "额度数据暂不可用"
            case .live: return "正在读取额度"
            }
        }

        let reset = QuotaFormatting.resetLabel(for: window.resetsAt)
        let quotaStatus: String
        if state.isDataStale {
            quotaStatus = "数据延迟"
        } else if state.quotaState == .connecting {
            quotaStatus = "正在更新"
        } else if window.remainingPercent == 0 {
            quotaStatus = "等待重置"
        } else if window.remainingPercent < 10 {
            quotaStatus = "即将用尽"
        } else if window.remainingPercent < 25 {
            quotaStatus = "偏低"
        } else {
            quotaStatus = reset
        }

        switch state.eyeRestPresentation.phase {
        case .focusing:
            let countdown = EyeRestFormatting.countdown(seconds: state.eyeRestPresentation.remainingSeconds)
            return "距远眺 \(countdown) · \(quotaStatus)"
        case .paused:
            let countdown = EyeRestFormatting.countdown(seconds: state.eyeRestPresentation.remainingSeconds)
            return "已暂停 \(countdown) · \(quotaStatus)"
        case .idle, .resting:
            return quotaStatus == reset ? reset : "\(quotaStatus) · \(reset)"
        }
    }

    private func accent(for window: QuotaWindow?) -> Color {
        guard let window else { return Palette.secondary }
        if window.remainingPercent < 10 { return Palette.critical }
        if window.remainingPercent < 25 { return Palette.low }
        return Palette.normal
    }

    private func statusColor(for window: QuotaWindow?) -> Color {
        if state.isDataStale || window == nil { return Palette.secondary }
        if (window?.remainingPercent ?? 100) < 25 {
            return accent(for: window).opacity(0.92)
        }
        return Palette.secondary
    }

    private func accessibilityText(for window: QuotaWindow?) -> String {
        guard let window else { return statusText(for: nil) }
        let freshness = state.isDataStale ? "，数据延迟" : ""
        let eyeRest: String
        switch state.eyeRestPresentation.phase {
        case .focusing:
            eyeRest = "，距离远眺还有 \(EyeRestFormatting.countdown(seconds: state.eyeRestPresentation.remainingSeconds))"
        case .paused:
            eyeRest = "，眼睛休息提醒已暂停，剩余 \(EyeRestFormatting.countdown(seconds: state.eyeRestPresentation.remainingSeconds))"
        case .idle, .resting:
            eyeRest = ""
        }
        return "Codex \(window.durationLabel)额度剩余 \(window.remainingPercent)%，\(QuotaFormatting.resetLabel(for: window.resetsAt))\(freshness)\(eyeRest)"
    }

    private var eyeRestAccessibilityText: String {
        "请看向约六米或更远处，自然眨眼，暂时不要看手机，剩余 \(state.eyeRestPresentation.remainingSeconds) 秒"
    }
}

private struct ResponsiveTypography {
    private static let defaultSize = CGSize(width: 228, height: 72)
    private static let maximumSize = CGSize(width: 420, height: 144)

    let scale: CGFloat

    init(containerSize: CGSize) {
        let widthRatio = containerSize.width / Self.defaultSize.width
        let heightRatio = containerSize.height / Self.defaultSize.height
        let limitingRatio = min(widthRatio, heightRatio)

        if limitingRatio < 1 {
            scale = max(0.92, limitingRatio)
        } else {
            let widthProgress = (containerSize.width - Self.defaultSize.width)
                / (Self.maximumSize.width - Self.defaultSize.width)
            let heightProgress = (containerSize.height - Self.defaultSize.height)
                / (Self.maximumSize.height - Self.defaultSize.height)
            let growthProgress = max(0, min(1, min(widthProgress, heightProgress)))
            scale = 1 + growthProgress * 0.5
        }
    }

    var title: CGFloat { 12 * scale }
    var percentage: CGFloat { 24 * scale }
    var status: CGFloat { 10.5 * scale }
    var detail: CGFloat { 10 * scale }
}

private enum Palette {
    static let base = rgb(0x1B, 0x1F, 0x20)
    static let surface = rgb(0x24, 0x28, 0x29)
    static let primary = rgb(0xE7, 0xE6, 0xE1)
    static let secondary = rgb(0x8C, 0x93, 0x90)
    static let normal = rgb(0x7D, 0x9B, 0x8A)
    static let low = rgb(0xC2, 0x9A, 0x5A)
    static let critical = rgb(0xB9, 0x6E, 0x62)
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
