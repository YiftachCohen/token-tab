// Token Tab — Mode A · Subscription (Claude Max/Pro).
//
// On a subscription the question is "how much have I got left?", so RUNWAY leads. The gauge
// is the centered hero; the runway sits beneath it, then the interpretation line. A "% left"
// means QUOTA, never the clock: a real token % appears only when a cap is configured (we
// never invent one). With no cap the same ring counts down the window's TIME — labeled as
// time, not usage — and offers an inline field to set the cap locally (UserDefaults).

import SwiftUI
import AppKit
import TokenTabCore

struct SubscriptionPanel: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var helper: LiveHelperManager
    let now: Date

    @State private var editingCap = false
    @State private var capText = ""
    @State private var showLiveHelp = false
    @State private var beat = false          // open-beat: sweep the ring from 0 on appear
    @FocusState private var capFocused: Bool

    private var snapshot: Snapshot { store.snapshot }
    private var w: WindowStats { snapshot.agg.window }

    // The framing fork: do we have a real QUOTA % (fresh live, or a cap), or only TIME?
    // `quota` also carries the source (live > cap), so a "% left" never means "% of the
    // clock", and a "· live" tag never ends up sitting over a cap estimate.
    private var quota: ClaudeQuota? { snapshot.quotaLeft(now: now) }
    private var quotaLeft: Int? { quota?.pct }
    private var hasQuota: Bool { quota != nil }
    private var isLive: Bool { quota?.source == .live }
    private var timeLeft: Double { w.timeLeftFraction(now: now) ?? 0 }
    private var secondarySessionQuota: ClaudeQuota? {
        snapshot.secondaryClaudeSessionQuota(now: now)
    }

    /// The ring's fill: quota-left when we have it, else the time countdown.
    private var heroFraction: Double { hasQuota ? Double(quotaLeft ?? 0) / 100 : timeLeft }

    /// Plain-language guidance for the binding allowance. Weekly server usage gets constraint
    /// copy because we cannot honestly turn its percentage into token runway; the session path
    /// retains the local-cap projection against Claude's own trailing-hour burn rate.
    private var paceLine: (text: String, health: Health)? {
        if let quota, quota.source == .live, quota.period == .weekly {
            switch quota.usedPct {
            case 100...: return ("Weekly limit reached", .throttled)
            case 90...:  return ("Weekly limit nearly reached", .throttled)
            case 70...:  return ("Weekly limit is getting close", .near)
            default:     return ("Weekly limit is your closest constraint", .healthy)
            }
        }
        guard w.active, w.cap > 0, let secs = w.secondsToReset(now: now), secs > 0 else { return nil }
        let left = max(0, w.cap - w.tokens)
        // Claude's own last hour ≈ tokens/hour. The combined `agg.lastHourTokens` counts
        // Codex too, and this rate is measured against Claude's own cap — so a busy Codex
        // hour would spend Claude's headroom on paper and raise a "Heavy pace" warning
        // against a window that is nowhere near full.
        let rate = snapshot.claudeLastHourTokens
        if rate <= 0 {
            return left > 0 ? ("At this pace, you're clear until reset", .healthy) : nil
        }
        let projected = Double(rate) * (secs / 3600)
        if projected <= Double(left) {
            return ("At this pace, you're clear until reset", .healthy)
        }
        let secsToCap = Double(left) / Double(rate) * 3600
        return ("Heavy pace — ~\(Fmt.duration(secsToCap)) of headroom left", .near)
    }

    /// The authoritative reset for whichever live allowance headlines the panel.
    private var liveResetText: String? {
        quota?.displayResetText
    }

    /// Why the hero stopped being a percentage, said once, where the staleness is already
    /// admitted. Without the second sentence the ring silently swaps a quota for a clock —
    /// same size, same position, same green — and the only clue is a caption change.
    private var staleLiveDetail: String {
        guard let capturedAt = snapshot.live?.capturedAt else {
            return "Live · stale — no successful reading yet"
        }
        let age = Fmt.duration(now.timeIntervalSince(capturedAt))
        if store.calibratedCapIsStale(now: now) {
            return "Live · stale — last reading \(age) ago. The learned cap expired with it, "
                 + "so the ring shows time left, not usage."
        }
        return "Live · stale — last successful reading \(age) ago"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // HERO — the gauge is the centered hero; the runway sits beneath it, then the
            // interpretation line. The center figure is a real quota % (live or cap), else the
            // window's time countdown; color carries health only when it's a quota.
            VStack(spacing: 0) {
                RingGauge(fraction: beat ? heroFraction : 0, size: 134, lineWidth: 12,
                          color: hasQuota ? snapshot.health.color : Theme.green) {
                    VStack(spacing: 1) {
                        if let pct = quotaLeft {
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                AnimatedNumber(target: Double(pct),
                                               font: Theme.hero(34, weight: .semibold),
                                               tracking: Theme.tightTracking(34),
                                               color: Theme.ink) { "\(Int($0.rounded()))" }
                                Text("%").font(Theme.figure(18)).foregroundStyle(Theme.faint)
                            }
                            heroCaption("left")
                        } else if w.active {
                            Text(Fmt.durationCompact(w.secondsToReset(now: now)))
                                .font(Theme.hero(26, weight: .semibold))
                                .tracking(Theme.tightTracking(26))
                                .foregroundStyle(Theme.ink)
                            heroCaption("left")
                        } else {
                            Text("idle").font(Theme.figure(20, weight: .semibold))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
                .padding(.top, 2)

                runwayBelow
                    .multilineTextAlignment(.center)
                    .padding(.top, 11)

                if let pace = paceLine {
                    Text(pace.text)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(pace.health.color)
                        .padding(.vertical, 4).padding(.horizontal, 10)
                        .background(pace.health.color.opacity(0.16), in: Capsule())
                        .padding(.top, 10)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 17).padding(.top, 16)

            // 5-HOUR SESSION — preserve the authoritative session allowance when weekly is the
            // binding hero, followed by this machine's local tokens and trend when active.
            if w.active || secondarySessionQuota != nil {
                Divider().background(Theme.hairline).padding(.horizontal, 17).padding(.top, 16)
                VStack(alignment: .leading, spacing: 7) {
                    SectionLabel(text: "5-HOUR SESSION")
                    if let session = secondarySessionQuota { sessionAllowance(session) }
                    if w.active {
                        statRow("Tokens used",
                                w.cap > 0 ? "\(Fmt.abbrev(w.tokens)) / \(Fmt.abbrev(w.cap))" : Fmt.abbrev(w.tokens),
                                color: Theme.ink)
                        // Claude's own rate — this row sits under the 5-HOUR SESSION heading,
                        // which is Claude's inferred window (see `paceLine`).
                        statRow("Trend", "+\(Fmt.abbrev(snapshot.claudeLastHourTokens)) / hr", color: Theme.green)
                    }
                }
                .padding(.horizontal, 17).padding(.top, 12)
            }

            // Two-up — this week (unless weekly already owns the hero) and all-time tokens.
            Divider().background(Theme.hairline).padding(.horizontal, 17).padding(.top, 14)
            HStack(alignment: .top, spacing: 12) {
                if snapshot.showsWeeklyDetail(now: now) {
                    weekCell
                    Spacer()
                    twoUp("All time", Fmt.abbrev(snapshot.agg.total))
                } else {
                    twoUp("All time", Fmt.abbrev(snapshot.agg.total), align: .leading)
                    Spacer()
                }
            }
            .padding(.horizontal, 17).padding(.top, 12)

            // Time-only: invite a local cap so the ring can show a real %.
            if !hasQuota && w.cap == 0 {
                capEditor.padding(.horizontal, 17).padding(.top, 12)
            }

            // TODAY · by model — the day's per-model token receipt (replaces the single agent row).
            Divider().background(Theme.hairline).padding(.horizontal, 17).padding(.top, 14)
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "TODAY · \(Fmt.abbrev(snapshot.agg.today)) · BY MODEL")
                todayByModelRows
            }
            .padding(.horizontal, 17).padding(.top, 12)

            // Live-setup row only when live is OFF or STALE; the trust line now lives in the
            // shared footer (DropdownView), so the panel just ends here when live is fresh.
            if !(snapshot.live?.isFresh(now: now) ?? false) {
                Divider().background(Theme.hairline).padding(.horizontal, 17).padding(.top, 14)
                liveSetupRow.padding(.vertical, 12)
            }
        }
        .padding(.bottom, 10)
        .onAppear { beat = true }
    }

    // MARK: hero pieces

    private func heroCaption(_ s: String) -> some View {
        Text(s).font(.system(size: 9, weight: .semibold)).tracking(1.2)
            .foregroundStyle(Theme.faint).textCase(.uppercase)
    }

    /// The runway line(s) under the gauge, centered, per state: live shows the authoritative
    /// reset, cap shows the big duration, time-only is explicit that it's the clock not usage.
    @ViewBuilder private var runwayBelow: some View {
        if isLive {
            VStack(spacing: 3) {
                Text(liveResetText.map { "resets \($0)" }
                     ?? (quota?.period == .weekly ? "weekly limit" : "live"))
                    .font(Theme.figure(17, weight: .semibold)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(quota?.period == .weekly ? "this week" : "this session") · from claude /usage")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if hasQuota {
            VStack(spacing: 3) {
                Text(w.active ? Fmt.duration(w.secondsToReset(now: now)) : "idle")
                    .font(Theme.hero(21, weight: .semibold)).tracking(Theme.tightTracking(21))
                    .foregroundStyle(Theme.ink)
                Text(w.active ? "until reset · \(Fmt.clock(w.resetAt))" : "no active window")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        } else {
            VStack(spacing: 3) {
                Text(w.active ? "resets \(Fmt.clock(w.resetAt))" : "no active window")
                    .font(Theme.figure(16, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(w.active ? "time left in this 5-hour window — not usage"
                              : "open Claude Code to start one")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: middle stats

    private func statRow(_ label: String, _ value: String, color: Color) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.ink.opacity(0.85))
            Spacer()
            Text(value).font(Theme.figure(12.5, weight: .semibold)).foregroundStyle(color)
        }
    }

    private func sessionAllowance(_ session: ClaudeQuota) -> some View {
        let health = Health.forQuota(usedPct: session.usedPct)
        return VStack(alignment: .leading, spacing: 4) {
            statRow("Session allowance", "\(session.pct)% left", color: health.color)
            HStack(spacing: 8) {
                MiniBar(fraction: Double(session.pct) / 100, color: health.color, height: 4)
                    .frame(width: 116)
                Spacer(minLength: 4)
                Text(session.displayResetText.map { "resets \($0)" } ?? "from claude /usage")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder private var weekCell: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("This week").font(.system(size: 11)).foregroundStyle(Theme.muted)
            if let weekly = snapshot.claudeWeeklyQuota(now: now) {
                let health = Health.forQuota(usedPct: weekly.usedPct)
                Text("\(weekly.pct)% left").font(Theme.figure(15, weight: .semibold)).foregroundStyle(Theme.ink)
                MiniBar(fraction: Double(weekly.pct) / 100, color: health.color, height: 4).frame(width: 116)
            } else {
                Text(Fmt.abbrev(snapshot.agg.thisWeek))
                    .font(Theme.figure(15, weight: .semibold)).foregroundStyle(Theme.ink)
            }
        }
    }

    // MARK: today · by model

    private struct ModelTok: Identifiable { let id = UUID(); let name: String; let tokens: Int; let color: Color }

    /// The day's per-model token receipt, from the History series' last (today) bucket — sorted
    /// by tokens. Reuses already-computed per-day maps, so Core stays untouched.
    private var todayByModelList: [ModelTok] {
        guard let today = snapshot.history.last else { return [] }
        return today.tokensByModel.filter { $0.value > 0 }.sorted { $0.value > $1.value }.enumerated().map { i, kv in
            ModelTok(name: prettyModel(kv.key), tokens: kv.value, color: subModelColor(kv.key, rank: i))
        }
    }

    /// Real model id → display name, but fold the parser's placeholder ids (`<synthetic>` /
    /// `<unknown>` / empty) into a clean "Other" so they never render raw in the receipt.
    private func prettyModel(_ base: String) -> String {
        let id = base.lowercased()
        if base.isEmpty || id == "<synthetic>" || id == "<unknown>" { return "Other" }
        return Fmt.modelName(base)
    }

    /// Stay in the green world: Claude tiers ramp green (top = brightest), Haiku slate, Codex indigo.
    private func subModelColor(_ base: String, rank: Int) -> Color {
        let id = base.lowercased()
        if id.contains("codex") || id.contains("gpt") || id.contains("fable") { return Theme.indigo }
        if id.contains("haiku") { return Theme.slate }
        return rank == 0 ? Theme.green : Theme.green.opacity(0.6)
    }

    @ViewBuilder private var todayByModelRows: some View {
        let rows = Array(todayByModelList.prefix(4))
        if rows.isEmpty {
            Text("No usage yet today").font(.system(size: 11)).foregroundStyle(Theme.faint)
        } else {
            ForEach(rows) { m in
                HStack(spacing: 9) {
                    Circle().fill(m.color).frame(width: 7, height: 7)
                    Text(m.name).font(.system(size: 12)).foregroundStyle(Theme.ink)
                    Spacer(minLength: 8)
                    Text(Fmt.abbrev(m.tokens)).font(Theme.figure(12, weight: .regular))
                        .foregroundStyle(Theme.muted).frame(width: 54, alignment: .trailing)
                }
            }
        }
    }

    // MARK: live setup — one click

    /// The live-setup affordance, shown only when live is OFF or STALE (gated at the call
    /// site). One click registers the bundled helper (SMAppService → Login Items); the
    /// copy-a-command fallback survives only where the toggle genuinely can't work (dev
    /// builds with no agent plist in the bundle).
    @ViewBuilder private var liveSetupRow: some View {
        switch helper.status {
        case .off:
            liveActionRow(dot: Theme.faint,
                          title: "Live %: off",
                          detail: "One click — a bundled helper runs `claude /usage` every ~5 min. Shows in Login Items.",
                          button: "Turn on") { helper.setEnabled(true) }
        case .requiresApproval:
            liveActionRow(dot: Theme.amber,
                          title: "Live % — approval needed",
                          detail: "macOS wants a nod first: allow Token Tab's helper under Login Items.",
                          button: "Open Login Items") { helper.openLoginItems() }
        case .on:
            // Enabled but the cache isn't fresh: right after turning on (first reading is
            // seconds away) or when readings stopped (claude signed out, machine asleep…).
            // Top-aligned: the expiry copy wraps to two lines, and a dot centered against a
            // two-line block reads as unanchored rather than as its bullet.
            HStack(alignment: .top, spacing: 6) {
                Circle().strokeBorder(Theme.faint, lineWidth: 1).frame(width: 6, height: 6)
                    .padding(.top, 3.5)
                Text(snapshot.live == nil ? "Live: on · waiting for the first reading…" : staleLiveDetail)
                    .font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)   // the expiry sentence wraps
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 17)
        case .unavailable:
            manualSetupRow
        }
    }

    /// One quiet row + one clear action, matching the panel's receipt density.
    private func liveActionRow(dot: Color, title: String, detail: String,
                               button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().strokeBorder(dot, lineWidth: 1).frame(width: 6, height: 6)
                Text(title).font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                Button(action: action) {
                    Text(button)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.vertical, 3).padding(.horizontal, 9)
                        .background(Theme.green, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Text(detail)
                .font(.system(size: 10)).foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 17)
    }

    /// Dev-build fallback (no agent plist in the bundle): the original hand-over of the
    /// exact command, because a toggle that can't work would be a lie.
    private var manualSetupRow: some View {
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
        .padding(.horizontal, 17)
    }

    private var liveHelp: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("The live % comes from `claude /usage`. This dev build has no bundled helper, so schedule the script one:")
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
    /// copied command runs from any directory. The chip still SHOWS the short relative form;
    /// only the copied string is the full path. Falls back to relative if unknown.
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

    private func twoUp(_ label: String, _ value: String,
                       align: HorizontalAlignment = .trailing) -> some View {
        VStack(alignment: align, spacing: 3) {
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
                    .textFieldStyle(.plain)
                    .font(Theme.figure(11))
                    .focused($capFocused)
                    .frame(maxWidth: .infinity)
                    .tokenFieldChrome(focused: capFocused)
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
