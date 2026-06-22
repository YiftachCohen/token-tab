// Token Tab — Mode A · Subscription (Claude Max/Pro).
//
// On a subscription the question is "how much have I got left?", so RUNWAY leads:
// a ring + the exact time remaining in the rolling 5-hour window. Tokens shrink to a
// side metric. A token % only appears when a cap is configured (we never invent one) —
// otherwise the runway is shown as exact time, which is always known.

import SwiftUI
import TokenTabCore

struct SubscriptionPanel: View {
    let snapshot: Snapshot
    let now: Date

    private var w: WindowStats { snapshot.agg.window }

    /// Window progress on a single basis: token-% when a cap is set, else time-elapsed.
    private var usedFraction: Double {
        if let used = w.tokenPct { return Double(used) / 100 }
        guard w.active, let secs = w.secondsToReset(now: now), w.blockSeconds > 0 else { return 0 }
        return max(0, min(1, 1 - secs / w.blockSeconds))
    }
    private var leftFraction: Double { max(0, 1 - usedFraction) }
    private var leftPct: Int { Int((leftFraction * 100).rounded()) }
    private var usedPct: Int { Int((usedFraction * 100).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(pill: Pill(text: "CLAUDE MAX", tint: Theme.green))

            // HERO: runway ring + time left
            HStack(alignment: .top, spacing: 18) {
                RingGauge(fraction: leftFraction, size: 104, lineWidth: 10, color: Theme.green) {
                    VStack(spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text("\(leftPct)").font(Theme.figure(30))
                            Text("%").font(Theme.figure(17)).foregroundStyle(Theme.faint)
                        }
                        Text("left").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    SectionLabel(text: "RUNWAY")
                    Text(w.active ? Fmt.duration(w.secondsToReset(now: now)) : "idle")
                        .font(Theme.figure(30, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text(w.active
                         ? "left in this 5-hour\nwindow · resets \(Fmt.clock(w.resetAt))"
                         : "no active window")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18).padding(.top, 16)

            // 5-hour session progress (time or token, same basis as the ring).
            barRow(title: "5-hour session",
                   trailing: w.tokenPct != nil ? "\(usedPct)% of cap" : "\(usedPct)% elapsed",
                   fraction: usedFraction, color: Theme.green)
                .padding(.horizontal, 18).padding(.top, 14)

            // Second stat: token cap bar when configured, else today/this-week tokens.
            Group {
                if w.cap > 0 {
                    barRow(title: "Window tokens",
                           trailing: "\(Fmt.abbrev(w.tokens)) / \(Fmt.abbrev(w.cap))",
                           fraction: usedFraction, color: Theme.indigo)
                } else {
                    HStack {
                        twoUp("Today", Fmt.abbrev(snapshot.agg.today))
                        Spacer()
                        twoUp("This week", Fmt.abbrev(snapshot.agg.thisWeek))
                    }
                }
            }
            .padding(.horizontal, 18).padding(.top, 13)

            Divider().background(Theme.hairline).padding(.horizontal, 18).padding(.top, 16)

            // SIDE METRIC: tokens today, demoted (Claude row; Codex hidden until its parser ships).
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(text: "TODAY · \(Fmt.abbrev(snapshot.agg.today)) TOKENS")
                    Spacer()
                    Text("side metric").font(.system(size: 10)).foregroundStyle(Theme.faint)
                }
                AgentRow(name: "Claude", color: Theme.green, split: snapshot.agg.todaySplit)
            }
            .padding(.horizontal, 18).padding(.top, 13)

            Divider().background(Theme.hairline).padding(.horizontal, 18).padding(.top, 14)
            TrustFooter(text: "Local only — nothing leaves this Mac")
                .padding(.vertical, 12)
        }
    }

    private func barRow(title: String, trailing: String, fraction: Double, color: Color) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundStyle(Theme.muted)
                Spacer()
                Text(trailing).font(Theme.figure(11, weight: .regular)).foregroundStyle(Theme.faint)
            }
            MiniBar(fraction: fraction, color: color)
        }
    }

    private func twoUp(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted)
            Text(value).font(Theme.figure(15, weight: .semibold)).foregroundStyle(Theme.ink)
        }
    }
}

/// One agent's token usage with a main/sub split bar (design's "solid main · faded sub").
struct AgentRow: View {
    var name: String
    var color: Color
    var split: MainSubSplit

    private var mainFrac: Double {
        split.total > 0 ? Double(split.mainTokens) / Double(split.total) : 0
    }
    private var subFrac: Double {
        split.total > 0 ? Double(split.subTokens) / Double(split.total) : 0
    }

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
            Text(name).font(.system(size: 12)).foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            MiniBar(fraction: mainFrac, subFraction: subFrac, color: color, height: 5)
                .frame(width: 74)
            Text(Fmt.abbrev(split.total))
                .font(Theme.figure(11, weight: .regular))
                .foregroundStyle(Theme.faint)
                .frame(width: 40, alignment: .trailing)
        }
    }
}
