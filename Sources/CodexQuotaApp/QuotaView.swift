import AppKit
import CodexQuotaCore
import SwiftUI

struct QuotaView: View {
    @EnvironmentObject private var state: QuotaAppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    /// Whether the pointer rests on the card (after a short delay); the card then shows today's full breakdown.
    @State private var isHovering = false
    @State private var hoverTask: Task<Void, Never>?
    /// QA renders force the breakdown.
    var previewHover = false
    /// Offline renders can't draw the AppKit tracking view.
    var tracksHover = true

    var body: some View {
        GeometryReader { proxy in
            let s = LayoutMetrics.scale(for: proxy.size)
            let isResting = state.eyeRestPresentation.phase == .resting
            let groups = [codexGroup, claudeGroup]
            let breakdown = isResting || !(previewHover || isHovering) ? nil : state.todayUsage

            ZStack {
                background(scale: s)

                Group {
                    if isResting {
                        restingContent(scale: s)
                    } else if let breakdown {
                        UsageBreakdown(usage: breakdown, rate: state.exchangeRate, scale: s)
                            .transition(.opacity)
                    } else {
                        regularContent(groups: groups, scale: s, width: proxy.size.width)
                            .transition(.opacity)
                    }
                }
                .padding(12 * s)
            }
            // One tracking area for the whole card, so swapping the content never moves it.
            .background {
                if tracksHover {
                    HoverTracker { inside in hoverChanged(inside) }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: groups.map(\.animationKey))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: state.eyeRestPresentation.phase)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: breakdown != nil)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isResting ? eyeRestAccessibilityText : accessibilityText(groups: groups))
            .contextMenu { QuotaMenuContent(items: QuotaMenu.items(for: state, placement: .overlay)) }
        }
    }

    // MARK: - Layouts

    private func regularContent(groups: [MeterGroup], scale s: CGFloat, width: CGFloat) -> some View {
        // Both tiles show or drop the "tokens" unit together, so the two rows always match.
        let tileTextWidth = (width - 2 * 12 * s - 8 * s) / 2 - 2 * 12 * s
        let showsUnit = groups.allSatisfy { TodayRowMetrics.fitsWithUnit($0.today, scale: s, width: tileTextWidth) }
        return VStack(alignment: .leading, spacing: 8 * s) {
            HStack(alignment: .top, spacing: 8 * s) {
                ForEach(groups) { group in
                    MeterTile(group: group, scale: s, showsTokenUnit: showsUnit, contrast: contrast)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            eyeRestFooter(scale: s)
        }
    }

    private func eyeRestFooter(scale s: CGFloat) -> some View {
        let phase = state.eyeRestPresentation.phase
        let countdown = EyeRestFormatting.countdown(seconds: state.eyeRestPresentation.remainingSeconds)
        let icon: String
        let text: String
        let color: Color
        switch phase {
        case .focusing:
            icon = "eye"
            text = "距远眺 \(countdown)"
            color = state.eyeRestPresentation.isWarning ? Palette.rest : Palette.primary.opacity(0.85)
        case .paused:
            icon = "pause.circle"
            text = "护眼计时已暂停 · 剩余 \(countdown)"
            color = Palette.secondary
        case .idle, .resting:
            icon = "eye.slash"
            text = "护眼未开始 · ⌃⌥R"
            color = Palette.tertiary
        }
        return HStack(spacing: 6 * s) {
            Image(systemName: icon)
                .font(.system(size: 13 * s, weight: .medium))
            Text(text)
                .font(.system(size: 14 * s, weight: .medium, design: .rounded))
                .monospacedDigit()
            Spacer(minLength: 8 * s)
            if let total = todayTotal {
                HStack(alignment: .firstTextBaseline, spacing: 5 * s) {
                    Text("今日合计")
                        .font(.system(size: 12 * s, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                    Text(total.money)
                        .font(.system(size: 15 * s, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.primary)
                }
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6 * s)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func restingContent(scale s: CGFloat) -> some View {
        let seconds = state.eyeRestPresentation.remainingSeconds
        return VStack(alignment: .leading, spacing: 10 * s) {
            HStack(alignment: .firstTextBaseline, spacing: 8 * s) {
                Image(systemName: "eye")
                    .font(.system(size: 18 * s, weight: .semibold))
                    .foregroundStyle(Palette.rest)
                Text("看向远处")
                    .font(.system(size: 20 * s, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                Spacer(minLength: 4)
                (Text("\(seconds)").font(.system(size: 52 * s, weight: .semibold, design: .rounded))
                    + Text(" 秒").font(.system(size: 17 * s, weight: .medium)))
                    .monospacedDigit()
                    .foregroundStyle(Palette.rest)
                    .contentTransition(.numericText())
            }
            Text("约 6 米外 · 自然眨眼 · 暂时不要看手机")
                .font(.system(size: 15 * s))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            MeterBar(
                progress: CGFloat(seconds) / 20,
                color: Palette.rest,
                height: (contrast == .increased ? 7 : 6) * s
            )
        }
        .padding(.horizontal, 6 * s)
        .padding(.vertical, 8 * s)
    }

    private func background(scale s: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20 * s, style: .continuous)
        return Group {
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
    }

    // MARK: - Hover

    private func hoverChanged(_ inside: Bool) {
        hoverTask?.cancel()
        if inside {
            // A short delay so passing the pointer over the card doesn't flip it.
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                isHovering = true
            }
        } else {
            isHovering = false
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
            hint: nil,
            today: todayLine(state.todayUsage?.codex, name: "Codex")
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
            hint: hint,
            today: todayLine(state.todayUsage?.claude, name: "Claude Code")
        )
    }

    /// Placeholder until the first scan finishes.
    private func todayLine(_ tally: TokenTally?, name: String) -> TodayLine {
        guard let tally, state.todayUsage != nil else {
            return TodayLine(tokens: "—", money: "")
        }
        return TodayLine(
            tokens: TokenFormatting.compactTokens(tally.totalTokens),
            money: UsageBreakdown.money(tally, rate: state.exchangeRate)
        )
    }

    private var todayTotal: TodayLine? {
        guard let usage = state.todayUsage else { return nil }
        return todayLine(usage.combined, name: "Claude Code + Codex")
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
        if let usage = state.todayUsage {
            for (name, tally) in [("Codex", usage.codex), ("Claude", usage.claude)] {
                let yuan = UsageBreakdown.money(tally, rate: state.exchangeRate)
                let hitRate = tally.cacheHitRate.map { "，命中率 \(TokenFormatting.percent($0))" } ?? ""
                parts.append(
                    "\(name) 今日 \(tally.requests) 次请求，\(TokenFormatting.compactTokens(tally.totalTokens)) tokens，约 \(yuan)；"
                        + "输入 \(TokenFormatting.compactTokens(tally.uncachedInputTokens))，"
                        + "缓存写入 \(TokenFormatting.compactTokens(tally.cacheWriteTokens))，"
                        + "缓存读取 \(TokenFormatting.compactTokens(tally.cacheReadTokens))，"
                        + "输出 \(TokenFormatting.compactTokens(tally.outputTokens))，"
                        + "缓存命中 \(TokenFormatting.compactTokens(tally.cacheReadTokens))，"
                        + "缓存未命中 \(TokenFormatting.compactTokens(tally.cacheMissTokens))\(hitRate)"
                )
            }
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
    let today: TodayLine

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

private struct TodayLine: Equatable {
    let tokens: String
    let money: String
}

// MARK: - Components

private struct MeterTile: View {
    let group: MeterGroup
    let scale: CGFloat
    let showsTokenUnit: Bool
    let contrast: ColorSchemeContrast

    var body: some View {
        let s = scale
        VStack(alignment: .leading, spacing: 6 * s) {
            header

            VStack(alignment: .leading, spacing: 6 * s) {
                tileBody
            }
            .frame(maxHeight: .infinity, alignment: .leading)

            todayRow
        }
        .padding(.horizontal, 12 * s)
        .padding(.vertical, 10 * s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14 * s, style: .continuous)
                .fill(Palette.tile)
                .overlay(
                    RoundedRectangle(cornerRadius: 14 * s, style: .continuous)
                        .stroke(Palette.tileBorder, lineWidth: contrast == .increased ? 1 : 0.5)
                )
        )
    }

    @ViewBuilder
    private var tileBody: some View {
        let s = scale
        if let hero = group.hero {
            HStack(alignment: .firstTextBaseline, spacing: 4 * s) {
                (Text("\(hero.remaining)").font(.system(size: 38 * s, weight: .semibold, design: .rounded))
                    + Text("%").font(.system(size: 18 * s, weight: .medium, design: .rounded)))
                    .foregroundStyle(group.numberColor(for: hero))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .opacity(group.isStale ? 0.62 : 1)
                    .fixedSize()
                Spacer(minLength: 2 * s)
                if let reset = hero.resetText {
                    Text(reset)
                        .font(.system(size: 13 * s, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }

            MeterBar(
                progress: CGFloat(hero.remaining) / 100,
                color: group.color(for: hero),
                height: (contrast == .increased ? 7 : 6) * s
            )
            .opacity(group.isStale ? 0.55 : 1)

            // One secondary window fits (e.g. the 5-hour one under a weekly hero); the rest stay in the menu tooltip.
            ForEach(group.details.prefix(1)) { meter in
                detailRow(meter)
            }
        } else {
            Text(group.message ?? "")
                .font(.system(size: 15 * s, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            if let hint = group.hint {
                Text(hint)
                    .font(.system(size: 12 * s, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .textSelection(.enabled)
            }
        }
    }

    private var todayRow: some View {
        let s = scale
        return VStack(alignment: .leading, spacing: 7 * s) {
            Rectangle()
                .fill(Palette.tileBorder)
                .frame(height: 1)
            todayContent(showsUnit: showsTokenUnit)
        }
    }

    private func todayContent(showsUnit: Bool) -> some View {
        let s = scale
        return HStack(alignment: .firstTextBaseline, spacing: 4 * s) {
            Text("今日")
                .font(.system(size: 12 * s, weight: .medium))
                .foregroundStyle(Palette.secondary)
            Text(group.today.tokens)
                .font(.system(size: 14 * s, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.primary.opacity(0.9))
            if showsUnit {
                Text("tokens")
                    .font(.system(size: 11 * s, weight: .medium))
                    .foregroundStyle(Palette.tertiary)
            }
            Spacer(minLength: 4 * s)
            Text(group.today.money)
                .font(.system(size: 15 * s, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.primary)
                .layoutPriority(1)
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var header: some View {
        let s = scale
        return HStack(spacing: 6 * s) {
            Circle()
                .fill(group.brand)
                .frame(width: 8 * s, height: 8 * s)
            Text(group.name)
                .font(.system(size: 15 * s, weight: .semibold))
                .foregroundStyle(Palette.primary.opacity(0.9))
            Spacer(minLength: 2 * s)
            if group.isStale {
                Text(group.isUpdating ? "更新中" : "数据延迟")
                    .font(.system(size: 12 * s, weight: .medium))
                    .foregroundStyle(Palette.tertiary)
            } else if let hero = group.hero {
                Text(hero.label)
                    .font(.system(size: 13 * s, weight: .medium))
                    .foregroundStyle(Palette.secondary)
            }
        }
        .lineLimit(1)
    }

    private func detailRow(_ meter: Meter) -> some View {
        let s = scale
        return HStack(spacing: 8 * s) {
            Text(meter.label)
                .font(.system(size: 13 * s, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
                .fixedSize()
            MeterBar(progress: CGFloat(meter.remaining) / 100, color: group.color(for: meter).opacity(0.8), height: 4 * s)
            Text("\(meter.remaining)%")
                .font(.system(size: 14 * s, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(group.numberColor(for: meter).opacity(0.9))
                .fixedSize()
        }
        .padding(.top, 2 * s)
        .opacity(group.isStale ? 0.62 : 1)
    }
}

/// Today's full breakdown for both tools, across the whole card while the pointer rests on it.
private struct UsageBreakdown: View {
    let usage: DailyTokenUsage
    let rate: ExchangeRate
    let scale: CGFloat

    private struct Row: Identifiable {
        let label: String
        let codex: String
        let claude: String
        /// A part of the row above ("其中…"), drawn indented and quieter.
        var isSubItem = false
        /// The bottom line of a table (the value in yuan).
        var isEmphasized = false
        var id: String { label }
    }

    static func money(_ tally: TokenTally, rate: ExchangeRate) -> String {
        let yuan = TokenFormatting.yuan(tally.usd * rate.usdToCNY)
        guard tally.unpricedTokens > 0 else { return yuan }
        return tally.usd > 0 ? "≥" + yuan : "未计价"
    }

    private static func dollars(_ tally: TokenTally) -> String {
        let dollars = TokenFormatting.dollars(tally.usd)
        return tally.unpricedTokens > 0 ? "≥" + dollars : dollars
    }

    private func row(_ label: String, subItem: Bool = false, emphasized: Bool = false, _ value: (TokenTally) -> String) -> Row {
        Row(label: label, codex: value(usage.codex), claude: value(usage.claude), isSubItem: subItem, isEmphasized: emphasized)
    }

    private var usageRows: [Row] {
        [
            row("请求次数") { "\($0.requests)" },
            row("总 tokens") { TokenFormatting.compactTokens($0.totalTokens) },
            row("输入") { TokenFormatting.compactTokens($0.uncachedInputTokens) },
            row("缓存写入") { TokenFormatting.compactTokens($0.cacheWriteTokens) },
            row("缓存读取") { TokenFormatting.compactTokens($0.cacheReadTokens) },
            row("输出") { TokenFormatting.compactTokens($0.outputTokens) }
        ]
    }

    private var cacheRows: [Row] {
        [
            row("缓存命中") { TokenFormatting.compactTokens($0.cacheReadTokens) },
            row("缓存未命中") { TokenFormatting.compactTokens($0.cacheMissTokens) },
            row("其中写入缓存", subItem: true) { TokenFormatting.compactTokens($0.cacheWriteTokens) },
            row("命中率") { $0.cacheHitRate.map(TokenFormatting.percent) ?? "—" },
            row("API 标价") { Self.dollars($0) },
            row("折合人民币", emphasized: true) { Self.money($0, rate: rate) }
        ]
    }

    var body: some View {
        let s = scale
        VStack(alignment: .leading, spacing: 8 * s) {
            HStack(alignment: .center, spacing: 12 * s) {
                table(title: "今日用量", rows: usageRows)
                Rectangle()
                    .fill(Palette.tileBorder)
                    .frame(width: 1)
                table(title: "缓存与金额", rows: cacheRows)
            }
            .frame(maxHeight: .infinity)

            footnote
        }
        .padding(.horizontal, 4 * s)
    }

    private func table(title: String, rows: [Row]) -> some View {
        let s = scale
        return Grid(alignment: .trailing, horizontalSpacing: 8 * s, verticalSpacing: 5 * s) {
            GridRow {
                Text(title)
                    .foregroundStyle(Palette.secondary)
                    .gridColumnAlignment(.leading)
                Text("Codex").foregroundStyle(Palette.codex)
                Text("Claude").foregroundStyle(Palette.claude)
            }
            .font(.system(size: 12 * s, weight: .semibold))

            ForEach(rows) { row in
                GridRow {
                    Text(row.label)
                        .font(.system(size: (row.isSubItem ? 11.5 : 12.5) * s, weight: .medium))
                        .foregroundStyle(row.isSubItem ? Palette.tertiary : Palette.secondary)
                        .padding(.leading, row.isSubItem ? 7 * s : 0)
                    Text(row.codex)
                    Text(row.claude)
                }
                .font(.system(size: (row.isSubItem ? 12.5 : 13.5) * s, weight: .semibold, design: .rounded))
                .foregroundStyle(row.isEmphasized ? Palette.primary : (row.isSubItem ? Palette.secondary : Palette.primary.opacity(0.88)))
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .frame(maxWidth: .infinity)
    }

    private var footnote: some View {
        let s = scale
        let combined = usage.combined
        var note = "汇率 1 美元 = \(String(format: "%.4f", rate.usdToCNY)) 元（\(rate.asOf) · \(rate.source)）"
        if combined.unpricedTokens > 0 {
            note += " · 另有 \(TokenFormatting.compactTokens(combined.unpricedTokens)) tokens 未计价"
        }
        return HStack(alignment: .firstTextBaseline, spacing: 6 * s) {
            Text("今日合计")
                .font(.system(size: 12 * s, weight: .medium))
                .foregroundStyle(Palette.secondary)
            Text(Self.money(combined, rate: rate))
                .font(.system(size: 14 * s, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Palette.primary)
            Text(note)
                .font(.system(size: 11 * s, weight: .medium))
                .foregroundStyle(Palette.tertiary)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
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

// MARK: - Hover tracking

/// Reports the pointer entering and leaving its area. The overlay never becomes key and the app is rarely
/// active, so this uses an always-active tracking area (SwiftUI's own hover and tooltips don't fire there).
/// It never takes clicks, so dragging and the right-click menu work as before.
private struct HoverTracker: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?
        private var trackingArea: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
    }
}

// MARK: - Layout

/// Text widths of a tile's "今日" row, measured with the same fonts the row uses.
private enum TodayRowMetrics {
    static func fitsWithUnit(_ line: TodayLine, scale s: CGFloat, width: CGFloat) -> Bool {
        let needed = textWidth("今日", size: 12 * s, weight: .medium)
            + textWidth(line.tokens, size: 14 * s, weight: .semibold, rounded: true)
            + textWidth("tokens", size: 11 * s, weight: .medium)
            + textWidth(line.money, size: 15 * s, weight: .semibold, rounded: true)
            + 4 * s * 4
        return needed <= width
    }

    private static func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight, rounded: Bool = false) -> CGFloat {
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        if rounded, let descriptor = font.fontDescriptor.withDesign(.rounded) {
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        let monospacedDigits = font.fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
            ]]
        ])
        font = NSFont(descriptor: monospacedDigits, size: size) ?? font
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// The card is designed once at `WindowStateStore.baseSize`; the window keeps that aspect ratio, so every
/// font, spacing and bar scales by the same factor when the window is resized from any edge.
enum LayoutMetrics {
    static func scale(for size: CGSize) -> CGFloat {
        let base = WindowStateStore.baseSize
        return max(0.5, min(size.width / base.width, size.height / base.height))
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
