// Token Tab — the menu-bar glyph.
//
// The number is decided by the active mode, and so is the glyph, matching each mock:
//   • Subscription → a runway RING (mono track + colored arc filled to runway-left) plus
//     "{remaining}%" of the window — token-% with a cap, else exact time remaining.
//   • Burn (Bedrock/API) → a health dot plus "$5.10" or "22.9M" today, per the toggle.
//
// TWO SHAPES, one per `MenuBarScope` (see the 2026-07-30 DESIGN.md rows):
//   • `.both` (default) → a glyph+figure pair PER PROVIDER, Claude always first so position
//     alone identifies them: "◔ 42%  ◕ 92%". Stable order is why neither pair needs a text
//     suffix. Only when BOTH providers have usage; otherwise it degrades to…
//   • `.headline` → the original single max-pressure figure, with the "Cdx" suffix when
//     Codex won, since one glyph can't say which provider it belongs to.
//
// Every percentage in this bar is "% LEFT", for both providers, which is also the direction
// the rings fill. Codex's official reading is natively "% used", so it's inverted here (a
// 92%-full ring beside the figure "8%" read as a contradiction, because it was one).
//
// In its own pair Codex shows whichever official window it published — 5h when there is one,
// else the weekly-only allowance current Codex builds emit — because that pair is Codex's own
// slot, not a comparison. Only the single `.headline` figure stays 5h-only, since that one IS
// a comparison against Claude's 5h % (the 2026-08-02 DESIGN.md row).
//
// The glyph is drawn as an NSImage (not a SwiftUI Shape) for historical reasons: under
// MenuBarExtra, custom shape-drawing was dropped in the status item, which is why the ring
// was invisible. That ceiling is gone — StatusItemController hosts this label in an
// NSHostingView now (MenuBarExtra also rendered only ONE Text + ONE Image, which truncated
// the two-provider label) — but NSImage rings work and are pixel-exact at 13pt, so they stay.
// The number stays monochrome so it's legible on any wallpaper; the ring/dot is the one spot
// we spend color.
//
// The figure/glyph properties are internal rather than private on purpose: every design
// decision in this file is string- or shape-shaped, so MenuBarLabelTests pins them directly
// (a SwiftUI body can't be asserted on). Nothing outside the tests reads them.

import SwiftUI
import AppKit
import TokenTabCore

struct MenuBarLabel: View {
    let snapshot: Snapshot
    let menuMetric: MenuMetric
    var scope: MenuBarScope = .both
    var now: Date = Date()
    /// True while the dropdown is open, i.e. while the status item is painting the system
    /// selection fill behind this label. Set by StatusItemController, not by SwiftUI.
    var selected: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            if showsBoth {
                pair(glyph: claudeGlyph, text: claudeFigure)
                pair(glyph: codexGlyph, text: codexFigure)
            } else {
                pair(glyph: glyph, text: text)
            }
        }
    }

    /// One provider's reading: its ring/dot, then its figure. 5pt is the original glyph-to-
    /// number gap; the 8pt between pairs (above) is what keeps two readings from fusing.
    private func pair(glyph: NSImage, text: String) -> some View {
        HStack(spacing: 5) {
            Image(nsImage: glyph)
            figure(text)
        }
    }

    private func figure(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(selected ? Theme.onMenuSelection : Color.primary)
    }

    /// Show a pair per provider only when both actually have usage — a lone ring stuck at
    /// 100% would be noise, and it keeps a Claude-only bar byte-identical to `.headline`.
    var showsBoth: Bool { scope == .both && snapshot.bothProvidersHaveUsage }

    /// The provider under most 5h-quota pressure, recomputed only when the snapshot ticks
    /// (30s) — no intra-tick flapping. Codex only wins when it has usage AND a higher REAL %.
    private var headline: Provider { snapshot.headlineProvider(now: now) }
    private var isCodex: Bool { headline == .codex }

    // MARK: - Dual label (one pair per provider)

    /// Claude's glyph in dual mode — identical to the single-label rule, since Claude's
    /// glyph never depended on which provider headlined.
    var claudeGlyph: NSImage {
        switch snapshot.mode {
        case .subscription: return MenuGlyph.ring(fraction: ringFraction, arc: NSColor(snapshot.health.color))
        case .burn:         return MenuGlyph.dot(color: NSColor(snapshot.health.color))
        }
    }

    /// Codex's glyph in dual mode: the indigo ring needs a REAL official %, so a Codex that
    /// has usage but no rate-limits reading yet gets a flat dot beside its token count —
    /// never a ring implying a percentage we don't have. Mirrors SecondaryProviderRow.
    var codexGlyph: NSImage {
        guard snapshot.codexDisplayUsedPct(now: now) != nil else { return MenuGlyph.dot(color: NSColor(Theme.indigo)) }
        return MenuGlyph.ring(fraction: codexRingFraction, arc: NSColor(Theme.indigo))
    }

    /// Claude's figure in dual mode. Unlike the single label, every fallback is Claude's OWN
    /// figure — tokens AND dollars — not the combined total: with a Codex pair right beside
    /// it, a combined figure would count Codex's usage into Claude's slot.
    var claudeFigure: String {
        switch snapshot.mode {
        case .subscription:
            if let q = snapshot.quotaLeft(now: now) { return "\(q.pct)%" }
            let w = snapshot.agg.window
            if w.active { return Fmt.durationCompact(w.secondsToReset(now: now)) }
            let today = snapshot.agg.providers["claude"]?.today ?? snapshot.agg.today
            return today > 0 ? Fmt.abbrev(today) : "—"
        case .burn:
            switch menuMetric {
            case .cost:   return Fmt.usd(snapshot.claudeCostToday)
            case .tokens: return Fmt.abbrev(snapshot.agg.providers["claude"]?.today ?? snapshot.agg.today)
            }
        }
    }

    /// Codex's figure in dual mode: its official % LEFT (matching Claude's reading and its own
    /// ring), else its day's tokens when there's no official reading to show. This is Codex's
    /// OWN slot, so it shows whichever official window Codex actually published — the 5h
    /// allowance when there is one, else the weekly-only one, exactly as the dropdown's Codex
    /// row and panel do. (`codexLeftPct` is the 5h-only reading, and it stays 5h-only where it
    /// belongs: `headlineProvider`, where a weekly % must never be compared with Claude's 5h %.
    /// Using it here is what made a weekly-only Codex — the current OpenAI shape — fall all the
    /// way through to a token count in the bar while the panel showed a percentage.)
    var codexFigure: String {
        if let left = snapshot.codexDisplayLeftPct(now: now) { return "\(left)%" }
        return Fmt.abbrev(snapshot.codex?.today ?? 0)
    }

    // MARK: - Single label (the max-pressure headline)

    var glyph: NSImage {
        // The indigo ring requires a REAL official % — Codex can headline without one (the
        // both-nil today-tokens fallback), and then glyph and text must both take the
        // mode-based path so the ring never contradicts the number beside it.
        if isCodex, snapshot.codexUsedPct(now: now) != nil {
            // Codex headlines its OFFICIAL 5h % (a real number) → a ring in the indigo accent,
            // filled to % LEFT (mirrors the panel hero). Uses .indigo, not a health color, since
            // Codex has no green/amber runway-health semantic.
            return MenuGlyph.ring(fraction: codexRingFraction, arc: NSColor(Theme.indigo))
        }
        switch snapshot.mode {
        case .subscription:
            return MenuGlyph.ring(fraction: ringFraction, arc: NSColor(snapshot.health.color))
        case .burn:
            return MenuGlyph.dot(color: NSColor(snapshot.health.color))
        }
    }

    /// Runway-left fraction for the ring (mirrors the panel ring): quota (live or cap) when
    /// we have one, else the time countdown. Same arc either way; the number says which.
    private var ringFraction: Double {
        if let q = snapshot.quotaLeft(now: now) { return Double(q.pct) / 100 }
        return snapshot.agg.window.timeLeftFraction(now: now) ?? 0
    }

    /// Codex ring: fraction LEFT of the official limit it is drawn beside (100 − usedPct) —
    /// the displayed window, so ring and figure can never disagree. In the single-label path
    /// that window is always the 5h one (only a 5h reading can headline).
    private var codexRingFraction: Double { Double(snapshot.codexDisplayLeftPct(now: now) ?? 0) / 100 }

    var text: String {
        // Codex focus: the official 5h window as "% LEFT" — the same reading as Claude's %
        // and as the ring beside it — with a "Cdx" suffix so a lone glyph is still
        // unambiguous (8% of the window spent reads "92% Cdx"). Codex always has a real % here.
        if isCodex, let left = snapshot.codexLeftPct(now: now) { return "\(left)% Cdx" }
        switch snapshot.mode {
        case .subscription:
            // A "%" only when it's a real quota % (live or cap). Otherwise show the time left
            // ("1h44") — honest about being a clock, never elapsed-time wearing a percent sign.
            if let q = snapshot.quotaLeft(now: now) { return "\(q.pct)%" }
            let w = snapshot.agg.window
            if w.active { return Fmt.durationCompact(w.secondsToReset(now: now)) }
            // No Claude runway either — fall back to combined today-tokens (both-empty case).
            if snapshot.codexHasUsage || snapshot.agg.today > 0 { return Fmt.millions(snapshot.agg.today) }
            return "—"
        case .burn:
            switch menuMetric {
            case .cost:   return Fmt.usd(snapshot.agg.cost?.today ?? 0)
            case .tokens: return Fmt.millions(snapshot.agg.today)
            }
        }
    }
}

/// NSImage glyphs for the menu bar. The track uses a dynamic system color so it stays
/// readable on both light and dark bars; the arc/dot carries the brand/health color.
enum MenuGlyph {
    static func ring(fraction: Double, arc: NSColor, diameter: CGFloat = 13, lineWidth: CGFloat = 2) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let img = NSImage(size: size, flipped: false) { rect in
            let inset = lineWidth / 2 + 0.5
            let r = rect.insetBy(dx: inset, dy: inset)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = r.width / 2

            // Track (full faint circle).
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            NSColor.tertiaryLabelColor.setStroke()
            track.stroke()

            // Arc: from 12 o'clock, clockwise, swept by `fraction`.
            let f = max(0, min(1, fraction))
            if f > 0 {
                let start: CGFloat = 90
                let arcPath = NSBezierPath()
                if f >= 0.999 {
                    arcPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                } else {
                    arcPath.appendArc(withCenter: center, radius: radius,
                                      startAngle: start, endAngle: start - CGFloat(f) * 360,
                                      clockwise: true)
                }
                arcPath.lineWidth = lineWidth
                arcPath.lineCapStyle = .round
                arc.setStroke()
                arcPath.stroke()
            }
            return true
        }
        img.isTemplate = false   // keep the colored arc; track adapts via the dynamic system color
        return img
    }

    static func dot(color: NSColor, diameter: CGFloat = 8) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let img = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }
}
