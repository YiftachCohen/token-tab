// Token Tab — the compact "other provider" hairline row (design §6).
//
// The Overview shows ONE provider as the hero gauge; the other provider (when it has usage)
// appears as this single compact hairline row below it — a small gauge/percent + one-line
// summary. Tapping it swaps focus (the tapped provider becomes the hero). A provider with
// zero usage is hidden entirely (the caller gates on that). No combined gauge, no cards —
// just an engraved secondary read, honoring the "card-less, hairline-divided" layout.

import SwiftUI
import TokenTabCore

struct SecondaryProviderRow: View {
    let provider: Provider
    let snapshot: Snapshot
    let now: Date
    let onTap: () -> Void

    private var accent: Color { provider.accent }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // A small ring in the provider's accent, filled to its % LEFT when it has a
                // real % (Codex official, Claude cap/live), else a dot when it doesn't.
                if let frac = ringFraction {
                    BrandMark(size: 20, lineWidth: 2.4, fraction: frac, color: accent, trackOpacity: 0.12)
                } else {
                    Circle().fill(accent).frame(width: 8, height: 8)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(summary).font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                // The trailing figure: the real % when there is one, else today-tokens.
                Text(trailing).font(Theme.figure(13, weight: .semibold)).foregroundStyle(accent)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.vertical, 9).padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var title: String { provider == .codex ? "Codex" : "Claude" }

    /// The provider's % LEFT (0…1) for the mini ring, when it has a REAL basis. nil → dot.
    private var ringFraction: Double? {
        switch provider {
        case .codex:
            return snapshot.codexDisplayLeftPct(now: now).map { Double($0) / 100 }
        case .claude:
            if let q = snapshot.quotaLeft(now: now) { return Double(q.pct) / 100 }
            return nil
        }
    }

    /// The trailing figure: a real "% left" when we have one, else the day's tokens.
    private var trailing: String {
        switch provider {
        case .codex:
            if let l = snapshot.codexDisplayLeftPct(now: now) { return "\(l)%" }
            return Fmt.abbrev(snapshot.codex?.today ?? 0)
        case .claude:
            if let q = snapshot.quotaLeft(now: now) { return "\(q.pct)%" }
            return Fmt.abbrev(snapshot.agg.providers["claude"]?.today ?? snapshot.agg.today)
        }
    }

    /// One-line summary: the official window read for Codex, the runway/today read for Claude.
    private var summary: String {
        switch provider {
        case .codex:
            if let used = snapshot.codexDisplayUsedPct(now: now) {
                let window = snapshot.codexDisplayWindow
                let period = window?.period == "weekly" ? "weekly" : "5h"
                let reset = window?.resetAt
                return reset != nil
                    ? "\(used)% of \(period) · resets \(Fmt.resetLabel(reset, relativeTo: now))"
                    : "\(used)% of official \(period) limit"
            }
            return "\(Fmt.abbrev(snapshot.codex?.today ?? 0)) today"
        case .claude:
            if snapshot.quotaLeft(now: now) != nil {
                let w = snapshot.agg.window
                return w.active ? "5h window · resets \(Fmt.clock(w.resetAt))" : "no active window"
            }
            return "\(Fmt.abbrev(snapshot.agg.providers["claude"]?.today ?? snapshot.agg.today)) today"
        }
    }
}
