// Token Tab — Mode A · Subscription (Claude Max/Pro).
//
// On a subscription the question is "how much have I got left?", so RUNWAY leads.
// The gauge holds the single "left" figure, and a "% left" means QUOTA, never the clock:
// a real token % appears only when a cap is configured (we never invent one). With no cap
// the same ring instead counts down the window's TIME — labeled as time, not usage — and
// offers an inline field to set the cap locally (UserDefaults), which flips it to a real %.

import SwiftUI
import TokenTabCore

struct SubscriptionPanel: View {
    @ObservedObject var store: UsageStore
    let now: Date

    @State private var editingCap = false
    @State private var capText = ""

    private var snapshot: Snapshot { store.snapshot }
    private var w: WindowStats { snapshot.agg.window }

    // The framing fork: do we have a real QUOTA % (fresh live, or a cap), or only TIME?
    // `quota` also carries the source (live > cap), so a "% left" never means "% of the
    // clock", and a "· live" tag never ends up sitting over a cap estimate.
    private var quota: (pct: Int, source: String)? { snapshot.quotaLeft(now: now) }
    private var quotaLeft: Int? { quota?.pct }
    private var hasQuota: Bool { quota != nil }
    private var isLive: Bool { quota?.source == "live" }
    private var timeLeft: Double { w.timeLeftFraction(now: now) ?? 0 }

    /// The ring's fill: quota-left when we have it, else the time countdown.
    private var heroFraction: Double { hasQuota ? Double(quotaLeft ?? 0) / 100 : timeLeft }
    /// The 5-hour bar's fill (used side): quota-used when we have a %, else time-elapsed.
    private var barUsed: Double { hasQuota ? Double(100 - (quotaLeft ?? 100)) / 100 : (1 - timeLeft) }
    private var barUsedPct: Int { max(0, min(100, Int((barUsed * 100).rounded()))) }
    private var barTrailing: String {
        if isLive { return "\(barUsedPct)% used · live" }
        if hasQuota { return "\(barUsedPct)% of cap" }
        return "\(barUsedPct)% elapsed"
    }

    /// The authoritative session reset from live, parenthetical timezone stripped for width
    /// ("12:29am (Europe/Rome)" → "12:29am"). nil when live carries no reset text.
    private var liveResetText: String? {
        guard let t = snapshot.live?.sessionResetText, !t.isEmpty else { return nil }
        if let r = t.range(of: " (") { return String(t[..<r.lowerBound]) }
        return t
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(pill: headerPill)

            // HERO: the gauge holds the single "left" figure — a real quota % when we have a
            // cap, otherwise the time remaining. Color carries health only when it's quota.
            HStack(alignment: .top, spacing: 18) {
                RingGauge(fraction: heroFraction, size: 104, lineWidth: 10,
                          color: hasQuota ? snapshot.health.color : Theme.green) {
                    VStack(spacing: 0) {
                        if let pct = quotaLeft {
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                Text("\(pct)").font(Theme.figure(31, weight: .semibold))
                                    .tracking(Theme.tightTracking(31))
                                Text("%").font(Theme.figure(17)).foregroundStyle(Theme.faint)
                            }
                            Text("left").font(.system(size: 10)).foregroundStyle(Theme.muted)
                        } else if w.active {
                            Text(Fmt.durationCompact(w.secondsToReset(now: now)))
                                .font(Theme.figure(24, weight: .semibold))
                                .tracking(Theme.tightTracking(24))
                            Text("left").font(.system(size: 10)).foregroundStyle(Theme.muted)
                        } else {
                            Text("idle").font(Theme.figure(20, weight: .semibold))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    SectionLabel(text: "RUNWAY")
                    if isLive {
                        // Live: show the authoritative reset, not our local heuristic clock.
                        Text(liveResetText.map { "resets \($0)" } ?? "live")
                            .font(Theme.figure(19, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("this session · from claude /usage")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if hasQuota {
                        // Cap-based %: our local window countdown is the supporting fact.
                        Text(w.active ? Fmt.duration(w.secondsToReset(now: now)) : "idle")
                            .font(Theme.figure(30, weight: .bold))
                            .tracking(Theme.tightTracking(30))
                            .foregroundStyle(Theme.ink)
                        Text(w.active
                             ? "left in this 5-hour\nwindow · resets \(Fmt.clock(w.resetAt))"
                             : "no active window")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        // Time-only: the ring already holds the duration. Be explicit that
                        // this is the clock, not usage, and point at how to get a real %.
                        Text(w.active ? "resets \(Fmt.clock(w.resetAt))" : "no active window")
                            .font(Theme.figure(19, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text(w.active
                             ? "time left in this 5-hour\nwindow — not usage"
                             : "open Claude Code to start one")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 6)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18).padding(.top, 16)

            // 5-hour session progress (live %, cap %, or time-elapsed — always labeled).
            barRow(title: "5-hour session",
                   trailing: barTrailing,
                   fraction: barUsed, color: Theme.green)
                .padding(.horizontal, 18).padding(.top, 14)

            // Weekly limit — only the live reading knows this. Shown whenever live is fresh
            // and carries a weekly %, independent of the session headline's source.
            if let l = snapshot.live, l.isFresh(now: now), let wk = l.weeklyPct {
                barRow(title: "This week (all models)",
                       trailing: "\(wk)% used · live",
                       fraction: Double(wk) / 100, color: Theme.indigo)
                    .padding(.horizontal, 18).padding(.top, 12)
            }

            // Second stat: token cap bar when configured, else today/this-week + a way to
            // set the cap so the gauge above can show a real %.
            Group {
                if w.cap > 0 {
                    barRow(title: "Window tokens",
                           trailing: "\(Fmt.abbrev(w.tokens)) / \(Fmt.abbrev(w.cap))",
                           fraction: barUsed, color: Theme.indigo)
                } else {
                    VStack(spacing: 11) {
                        HStack {
                            twoUp("Today", Fmt.abbrev(snapshot.agg.today))
                            Spacer()
                            twoUp("This week", Fmt.abbrev(snapshot.agg.thisWeek))
                        }
                        // Only invite a cap when there's no % at all — never under a live %.
                        if !hasQuota { capEditor }
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

    /// Header badge: a pulsing LIVE dot when the % is from a fresh `claude /usage` reading,
    /// then the plan pill. The dot is the at-a-glance "these numbers are authoritative" cue.
    @ViewBuilder private var headerPill: some View {
        HStack(spacing: 7) {
            if isLive {
                HStack(spacing: 4) {
                    GlowDot(color: Theme.green, size: 5, glow: 3)
                    Text("LIVE").font(.system(size: 9, weight: .bold)).tracking(0.6)
                        .foregroundStyle(Theme.green)
                }
            }
            Pill(text: "CLAUDE MAX", tint: Theme.green)
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

    /// Set the 5-hour token cap locally (UserDefaults). A collapsed prompt that expands to a
    /// field — entering a cap flips the runway above into a real quota %. Stays on this Mac.
    @ViewBuilder private var capEditor: some View {
        if editingCap {
            HStack(spacing: 8) {
                TextField("tokens, e.g. 220000000", text: $capText)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.figure(11))
                    .frame(maxWidth: .infinity)
                    .onSubmit(commitCap)
                Button("Save", action: commitCap)
                    .buttonStyle(.borderedProminent).tint(Theme.green)
                    .font(.system(size: 11, weight: .semibold))
                Button("Cancel") { editingCap = false }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
        } else {
            Button {
                capText = store.capOverride > 0 ? String(store.capOverride) : ""
                editingCap = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.needle").font(.system(size: 11))
                    Text("Set your 5-hour token cap to see % used")
                        .font(.system(size: 11))
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Theme.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Parse digits only (tolerate "220,000,000"/"220_000_000") and persist. Empty/0 clears
    /// the override, falling back to env/dotfile config or the honest time countdown.
    private func commitCap() {
        store.capOverride = Int(capText.filter(\.isNumber)) ?? 0
        editingCap = false
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
