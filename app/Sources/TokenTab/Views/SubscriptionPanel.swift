// Token Tab — Mode A · Subscription (Claude Max/Pro).
//
// On a subscription the question is "how much have I got left?", so RUNWAY leads.
// The gauge holds the single "left" figure, and a "% left" means QUOTA, never the clock:
// a real token % appears only when a cap is configured (we never invent one). With no cap
// the same ring instead counts down the window's TIME — labeled as time, not usage — and
// offers an inline field to set the cap locally (UserDefaults), which flips it to a real %.

import SwiftUI
import AppKit
import TokenTabCore

struct SubscriptionPanel: View {
    @ObservedObject var store: UsageStore
    let now: Date

    @State private var editingCap = false
    @State private var capText = ""
    @State private var showLiveHelp = false

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

            // 5-hour session — the WINDOW'S TIME progress. The ring above already owns the
            // quota % (and "% used" is just its complement), so this row shows how far through
            // the 5-hour block we are — its own title — instead of restating the gauge. Fill =
            // elapsed; trailing = time remaining.
            barRow(title: "5-hour session",
                   trailing: w.active ? "\(Fmt.duration(w.secondsToReset(now: now))) left" : "window idle",
                   fraction: w.active ? max(0, 1 - timeLeft) : 0, color: Theme.green)
                .padding(.horizontal, 18).padding(.top, 14)

            // Weekly limit — only the live reading knows this. Shown whenever live is fresh
            // and carries a weekly %, independent of the session headline's source.
            if let l = snapshot.live, l.isFresh(now: now), let wk = l.weeklyPct {
                barRow(title: "This week (all models)",
                       trailing: "\(wk)% used",
                       fraction: Double(wk) / 100, color: Theme.indigo)
                    .padding(.horizontal, 18).padding(.top, 12)
            }

            // Second stat: token cap bar when configured, else today/this-week + a way to
            // set the cap so the gauge above can show a real %.
            Group {
                if w.cap > 0 {
                    barRow(title: "Window tokens",
                           trailing: "\(Fmt.abbrev(w.tokens)) / \(Fmt.abbrev(w.cap))",
                           fraction: Double(w.tokens) / Double(w.cap), color: Theme.indigo)
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
                SectionLabel(text: "TODAY · \(Fmt.abbrev(snapshot.agg.today)) TOKENS")
                AgentRow(name: "Claude", color: Theme.green, split: snapshot.agg.todaySplit)
            }
            .padding(.horizontal, 18).padding(.top, 13)

            Divider().background(Theme.hairline).padding(.horizontal, 18).padding(.top, 14)
            VStack(alignment: .leading, spacing: 9) {
                liveStatusRow
                TrustFooter(text: "Local only — nothing leaves this Mac")
            }
            .padding(.vertical, 12)
        }
    }

    /// Footer line that makes the live boundary legible: where the % comes from, whether
    /// it's fresh — and, when it isn't, the exact command to turn it on. The app can't run
    /// the sidecar itself (sandboxed, no network), so honesty here means handing over the
    /// command, not hiding a button that could never work.
    @ViewBuilder private var liveStatusRow: some View {
        if let l = snapshot.live, l.isFresh(now: now) {
            HStack(spacing: 6) {
                GlowDot(color: Theme.green, size: 5, glow: 3)
                Text("Live · claude /usage · \(liveAgo(l))")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 18)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Button { withAnimation(.easeOut(duration: 0.15)) { showLiveHelp.toggle() } } label: {
                    HStack(spacing: 6) {
                        Circle().strokeBorder(Theme.faint, lineWidth: 1).frame(width: 6, height: 6)
                        Text(snapshot.live == nil ? "Live %: off" : "Live · stale")
                            .font(.system(size: 10.5))
                        Image(systemName: showLiveHelp ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.faint).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showLiveHelp { liveHelp }
            }
            .padding(.horizontal, 18)
        }
    }

    private var liveHelp: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("The live % comes from `claude /usage`. This app is sandboxed (no network), so a small helper fetches it. One-time setup — it installs a background agent that refreshes every ~5 min:")
                .font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            commandChip(display: "adapters/install-live.sh", copy: installCopy, note: "auto-refresh")
            commandChip(display: "node adapters/write-live.mjs", copy: nodeCopy, note: "once")
            Text(adaptersDir == nil
                 ? "Run from the Token Tab folder. See README › Turn on live."
                 : "Copy → paste in Terminal once; it keeps running in the background. Stop it with `install-live.sh uninstall`. See README › Turn on live.")
                .font(.system(size: 10)).foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transition(.opacity)
    }

    /// Absolute, cwd-independent commands when we can locate the repo's `adapters/` — so the
    /// copied command runs from any directory. The chip still SHOWS the short relative form
    /// (readable); only the copied string is the full path. Falls back to relative if unknown.
    private var adaptersDir: URL? { Config.adaptersDir() }
    private var installCopy: String {
        adaptersDir.map { shellQuoted($0.appendingPathComponent("install-live.sh")) } ?? "adapters/install-live.sh"
    }
    private var nodeCopy: String {
        adaptersDir.map { "node " + shellQuoted($0.appendingPathComponent("write-live.mjs")) } ?? "node adapters/write-live.mjs"
    }
    private func shellQuoted(_ url: URL) -> String { "'" + url.path + "'" }  // path may contain spaces

    private func commandChip(display: String, copy: String, note: String) -> some View {
        HStack(spacing: 8) {
            Text(display).font(Theme.mono(10)).foregroundStyle(Theme.ink)
                .lineLimit(1).truncationMode(.middle)
                .padding(.vertical, 4).padding(.horizontal, 7)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 6))
            Button { copyCommand(copy) } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 10))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.green)
            Text(note).font(.system(size: 9.5)).foregroundStyle(Theme.faint)
            Spacer(minLength: 0)
        }
    }

    private func copyCommand(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func liveAgo(_ l: LiveUsage) -> String {
        guard let c = l.capturedAt else { return "just now" }
        let s = Int(now.timeIntervalSince(c))
        return s < 60 ? "\(max(0, s))s ago" : "\(s / 60)m ago"
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
                // The value is what the user came to read; it must not be dimmer than its
                // label. `muted` (not `faint`) keeps it legible and above the AA contrast floor.
                Text(trailing).font(Theme.figure(11, weight: .regular)).foregroundStyle(Theme.muted)
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
