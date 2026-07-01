// Token Tab — the History tab.
//
// "Tap the menu-bar total to drop into daily history." A 7 / 14 / 30-day daily bar chart
// with a $ / tokens switch — the chart, the period total, the delta-vs-previous-period and
// the "busiest model" all re-shape together (Opus leads on cost, Sonnet on volume). The
// sensible default per mode mirrors the headline: tokens on a subscription, $ on pay-per-token.
//
// Every number is sliced from the precomputed 60-day `snapshot.history`, so toggling range
// or metric is instant and re-reads nothing.

import SwiftUI
import TokenTabCore

enum HistMetric: Hashable { case cost, tokens }

struct HistoryPanel: View {
    let snapshot: Snapshot
    @Environment(\.colorScheme) private var scheme

    @State private var range: Int
    @State private var metric: HistMetric
    @State private var chartProgress: Double = 0   // open-beat: bars grow on appear
    /// Kept so the chart can carry color-as-mode: green bars on a subscription, amber on
    /// pay-per-token (a cost chart drawn in green would cross-wire the green=health semantic).
    private let mode: Mode

    /// Default the metric to the mode's headline: tokens on a subscription, $ on pay-per-token.
    init(snapshot: Snapshot, mode: Mode) {
        self.snapshot = snapshot
        self.mode = mode
        _range = State(initialValue: 14)
        _metric = State(initialValue: mode == .subscription ? .tokens : .cost)
    }

    // MARK: derived series

    private var daily: [DayUsage] { snapshot.history }
    private var isTok: Bool { metric == .tokens }
    private func value(_ d: DayUsage) -> Double { isTok ? Double(d.tokens) : d.cost }

    /// The shown window (last `range` days) and the prior `range` days for the delta.
    private var shown: [DayUsage] { Array(daily.suffix(range)) }
    private var prev: [DayUsage] {
        let end = daily.count - range
        guard end > 0 else { return [] }
        return Array(daily[max(0, end - range)..<end])
    }

    private var total: Double { shown.reduce(0) { $0 + value($1) } }
    private var prevTotal: Double { prev.reduce(0) { $0 + value($1) } }
    private var hasPrev: Bool { prevTotal > 0 }
    private var deltaPct: Int { hasPrev ? Int(((total - prevTotal) / prevTotal * 100).rounded()) : 0 }
    private var avg: Double { shown.isEmpty ? 0 : total / Double(shown.count) }
    private var maxValue: Double { shown.map(value).max() ?? 0 }

    private var periodVerb: String { isTok ? "USED" : "SPENT" }
    private var periodTotal: String { isTok ? Fmt.abbrev(Int(total.rounded())) : Fmt.usd(total) }
    private var periodAvg: String { isTok ? Fmt.abbrev(Int(avg.rounded())) : Fmt.usd(avg) }

    /// The model with the most tokens (or cost) across the shown window, with its accent —
    /// nil until there's any priced/counted usage to rank.
    private var busiest: (name: String, color: Color)? {
        var totals: [String: Double] = [:]
        for d in shown {
            if isTok { for (m, t) in d.tokensByModel { totals[m, default: 0] += Double(t) } }
            else     { for (m, c) in d.costByModel  { totals[m, default: 0] += c } }
        }
        guard let top = totals.max(by: { $0.value < $1.value }), top.value > 0 else { return nil }
        return (Fmt.modelName(top.key), modelColor(top.key))
    }

    private var bars: [HistBar] {
        let last = shown.count - 1
        return shown.enumerated().map { i, d in
            HistBar(value: value(d), weekend: d.weekend, today: i == last)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // $ / Tok (left) · 7d / 14d / 30d (right)
            HStack {
                MiniSegmented(options: [("$", .cost), ("Tok", .tokens)],
                              selection: $metric, hPadding: 10)
                Spacer()
                MiniSegmented(options: [("7d", 7), ("14d", 14), ("30d", 30)],
                              selection: $range, hPadding: 11)
            }
            .padding(.horizontal, 17).padding(.top, 12)

            // Period total + delta-vs-previous badge
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "\(periodVerb) · LAST \(range) DAYS")
                HStack(alignment: .firstTextBaseline, spacing: 11) {
                    AnimatedNumber(target: total,
                                   font: Theme.hero(34, weight: .bold),
                                   tracking: Theme.tightTracking(34),
                                   color: Theme.ink) { isTok ? Fmt.abbrev(Int($0.rounded())) : Fmt.usd($0) }
                    if hasPrev { DeltaBadge(deltaPct: deltaPct) }
                }
                .padding(.top, 7)
            }
            .padding(.horizontal, 17).padding(.top, 14)

            // Daily bars + axis
            VStack(spacing: 6) {
                if maxValue > 0 {
                    // Color carries the mode. Subscription: green bars, amber "today" (pops by
                    // hue). Bedrock/API (cost): an all-amber chart — a calmer amber body with the
                    // brightest amber for today — so the $ chart stays true to amber=cost.
                    let burn = mode != .subscription
                    HistoryChart(bars: bars, maxValue: maxValue, avg: avg,
                                 bar: burn ? solid(0xC2740F, 0xF5B44D).opacity(0.5)
                                           : solid(0x2E9E63, 0x36C98A),
                                 today: burn ? solid(0xC2740F, 0xF5B44D)
                                             : solid(0xC08A3E, 0xD6A45A),
                                 avgLine: solid(0x76736D, 0x9AA1B1).opacity(0.55),
                                 progress: chartProgress)
                        .frame(height: 74)
                        .onAppear {
                            chartProgress = 0
                            withAnimation(.easeOut(duration: OpenBeat.duration)) { chartProgress = 1 }
                        }
                } else {
                    Text("No usage in this range yet")
                        .font(.system(size: 11)).foregroundStyle(Theme.faint)
                        .frame(maxWidth: .infinity, minHeight: 74)
                }
                HStack {
                    Text("\u{2212}\(range)d")
                        .font(Theme.figure(9.5, weight: .regular)).foregroundStyle(Theme.faint)
                    Spacer()
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(mode == .subscription ? Theme.amberBar : Theme.amber)
                            .frame(width: 7, height: 5)
                        Text("today").font(.system(size: 9.5)).foregroundStyle(Theme.faint)
                    }
                }
            }
            .padding(.horizontal, 17).padding(.top, 12)

            // AVG / DAY · BUSIEST MODEL
            Divider().background(Theme.hairline).padding(.horizontal, 17).padding(.top, 12)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(text: "AVG / DAY")
                    Text(periodAvg).font(Theme.figure(14, weight: .semibold)).foregroundStyle(Theme.ink)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    SectionLabel(text: "BUSIEST MODEL")
                    Text(busiest?.name ?? "—")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(busiest?.color ?? Theme.muted)
                }
            }
            .padding(.horizontal, 17).padding(.top, 12)

        }
        .padding(.bottom, 12)
    }

    /// Family → accent: Opus amber (cost leader), Sonnet green (volume leader), Haiku slate,
    /// Codex/Fable indigo, anything else muted.
    private func modelColor(_ base: String) -> Color {
        let id = base.lowercased()
        if id.contains("opus") { return Theme.amberBar }
        if id.contains("sonnet") { return Theme.green }
        if id.contains("haiku") { return Theme.slate }
        if id.contains("fable") || id.contains("gpt") || id.contains("codex") { return Theme.indigo }
        return Theme.muted
    }

    /// A scheme-resolved solid color — Canvas draws with concrete colors, so we pick the
    /// light/dark value here rather than rely on a dynamic color resolving inside the Canvas.
    private func solid(_ light: Int, _ dark: Int) -> Color {
        Color(hex8: scheme == .dark ? dark : light)
    }
}

/// One bar in the History chart.
struct HistBar {
    var value: Double
    var weekend: Bool
    var today: Bool
}

/// The daily bar chart: a dashed average line behind rounded bars. Today is amber, weekends
/// are a faded green, weekdays solid green — matching the design's fill rules. Bar width and
/// gap scale with the day count (wider bars at 7d, thinner at 30d).
struct HistoryChart: View, Animatable {
    var bars: [HistBar]
    var maxValue: Double
    var avg: Double
    var bar: Color
    var today: Color
    var avgLine: Color
    var progress: Double = 1            // open-beat: bars grow from the baseline (0 → full)

    // Drives the Canvas redraw each eased frame as the bars grow in.
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { ctx, size in
            let n = bars.count
            guard n > 0, maxValue > 0 else { return }
            let H = size.height, W = size.width
            let gap: CGFloat = n <= 7 ? 6 : n <= 14 ? 3 : 2
            let bw = max(1, (W - gap * CGFloat(n - 1)) / CGFloat(n))

            // Dashed average line.
            let avgH = max(2, CGFloat(avg / maxValue) * (H - 3))
            let avgY = H - avgH
            var line = Path()
            line.move(to: CGPoint(x: 0, y: avgY))
            line.addLine(to: CGPoint(x: W, y: avgY))
            ctx.stroke(line, with: .color(avgLine),
                       style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

            // Bars.
            for (i, b) in bars.enumerated() {
                let h = max(2, CGFloat(b.value / maxValue) * (H - 3)) * progress
                let x = CGFloat(i) * (bw + gap)
                let rect = CGRect(x: x, y: H - h, width: bw, height: h)
                let color = b.today ? today : (b.weekend ? bar.opacity(0.3) : bar)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.4), with: .color(color))
            }
        }
    }
}
