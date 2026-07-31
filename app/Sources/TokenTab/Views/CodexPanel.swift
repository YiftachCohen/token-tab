// Token Tab — Overview · Codex (OpenAI Codex CLI).
//
// When Codex is the focused provider, it renders as the SAME hero gauge Claude uses, but the
// number is the OFFICIAL 5-hour used-percentage OpenAI reports in the logs (never inferred),
// so the ring reads "% left" of a real quota. Accent is Theme.indigo (DESIGN.md: indigo =
// Codex). Below the hero: the official interpretation line ("official 5-hour limit · resets
// 14:35"), a weekly mini bar, and the day's per-model token receipt. A subtle "as of HH:MM"
// affordance appears when the snapshot is older than ~10 min (design §3) so we never imply
// a live reading. There is deliberately NO combined quota gauge (both blind designs agreed
// a merged Claude+Codex % is mathematically fake).

import SwiftUI
import TokenTabCore

struct CodexPanel: View {
    @ObservedObject var store: UsageStore
    let now: Date

    @State private var beat = false          // open-beat: sweep the ring from 0 on appear

    private var snapshot: Snapshot { store.snapshot }
    private var accent: Color { Theme.indigo }

    // The Codex hero is % LEFT of the official 5h limit. Codex is only ever focused when it
    // has usage, and usage implies a rate-limits snapshot, so these are populated here — but
    // we fail soft to an "idle" read if a snapshot is somehow absent.
    private var usedPct: Int? { snapshot.codexUsedPct(now: now) }
    private var leftPct: Int? { snapshot.codexLeftPct(now: now) }
    private var heroFraction: Double { Double(leftPct ?? 0) / 100 }
    private var stale: Bool { snapshot.codexStale(now: now) }
    private var resetAt: Date? { snapshot.codexPrimary?.resetAt }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // HERO — the official 5h gauge, centered like Claude's runway ring.
            VStack(spacing: 0) {
                RingGauge(fraction: beat ? heroFraction : 0, size: 134, lineWidth: 12, color: accent) {
                    VStack(spacing: 1) {
                        if let pct = leftPct {
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                AnimatedNumber(target: Double(pct),
                                               font: Theme.hero(34, weight: .semibold),
                                               tracking: Theme.tightTracking(34),
                                               color: Theme.ink) { "\(Int($0.rounded()))" }
                                Text("%").font(Theme.figure(18)).foregroundStyle(Theme.faint)
                            }
                            heroCaption("left")
                        } else {
                            Text("idle").font(Theme.figure(20, weight: .semibold))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
                .padding(.top, 2)

                // Interpretation line — the design's per-mode plain-language read.
                VStack(spacing: 3) {
                    Text(interpretation)
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if stale, let asOf = snapshot.codexAsOf {
                        // Not live — the official % is only as fresh as the newest token_count.
                        Text("as of \(Fmt.clock(asOf))")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.top, 11)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 17).padding(.top, 16)

            // THIS WEEK — the official weekly window as a secondary mini bar.
            if let wk = snapshot.codexWeeklyUsedPct(now: now) {
                Divider().background(Theme.hairline).padding(.horizontal, 17).padding(.top, 16)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text("This week").font(.system(size: 12)).foregroundStyle(Theme.ink.opacity(0.85))
                        Spacer()
                        Text("\(wk)% used").font(Theme.figure(12.5, weight: .semibold)).foregroundStyle(accent)
                        if !weeklyResetText.isEmpty {
                            Text(weeklyResetText).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                    }
                    MiniBar(fraction: Double(wk) / 100, color: accent, height: 4)
                }
                .padding(.horizontal, 17).padding(.top, 12)
            }

            // 5-HOUR SESSION — the rolling Codex token volume in this window (informational;
            // the % above is the authoritative quota read, tokens just show the raw scale).
            Divider().background(Theme.hairline).padding(.horizontal, 17).padding(.top, 14)
            HStack(alignment: .top, spacing: 12) {
                twoUp("This 5h", Fmt.abbrev(snapshot.codex?.rolling5h ?? 0), align: .leading)
                Spacer()
                twoUp("All time", Fmt.abbrev(snapshot.codex?.total ?? 0))
            }
            .padding(.horizontal, 17).padding(.top, 12)

            // TODAY · by model — the day's Codex per-model token receipt.
            Divider().background(Theme.hairline).padding(.horizontal, 17).padding(.top, 14)
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "TODAY · \(Fmt.abbrev(snapshot.codex?.today ?? 0)) · BY MODEL")
                todayByModelRows
            }
            .padding(.horizontal, 17).padding(.top, 12)

            // Unpriced footnote — some Codex models are unpriced by design (design §3).
            if unpricedCodexPresent {
                Text("some Codex models unpriced")
                    .font(.system(size: 10)).foregroundStyle(Theme.faint)
                    .padding(.horizontal, 17).padding(.top, 10)
            }
        }
        .padding(.bottom, 10)
        .onAppear { beat = true }
    }

    /// The line under the hero. Once the recorded window has passed its reset the gauge shows
    /// "idle" (the % belongs to a window that no longer exists), so the caption must say that
    /// rather than promise a reset that already happened — otherwise the panel reads as an
    /// active quota with a mysteriously blank number.
    private var interpretation: String {
        guard let resetAt else { return "official 5-hour limit" }
        return snapshot.codexWindowExpired(now: now)
            ? "official 5-hour limit · window reset at \(Fmt.clock(resetAt))"
            : "official 5-hour limit · resets \(Fmt.clock(resetAt))"
    }

    private var weeklyResetText: String {
        guard let r = snapshot.codexSecondary?.resetAt else { return "" }
        return "· resets \(Fmt.clock(r))"
    }

    /// The unpriced bucket is combined across providers; only flag "Codex models unpriced"
    /// when at least one unpriced model id looks like a Codex/gpt id (avoids blaming Codex
    /// for an unpriced Claude id).
    private var unpricedCodexPresent: Bool {
        guard let models = snapshot.agg.cost?.unpricedModels, !models.isEmpty else { return false }
        return models.contains { let m = $0.lowercased(); return m.contains("codex") || m.contains("gpt") }
    }

    private func heroCaption(_ s: String) -> some View {
        Text(s).font(.system(size: 9, weight: .semibold)).tracking(1.2)
            .foregroundStyle(Theme.faint).textCase(.uppercase)
    }

    private func twoUp(_ label: String, _ value: String, align: HorizontalAlignment = .trailing) -> some View {
        VStack(alignment: align, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted)
            Text(value).font(Theme.figure(15, weight: .semibold)).foregroundStyle(Theme.ink)
        }
    }

    // MARK: today · by model (Codex records only)

    private struct ModelTok: Identifiable { let id = UUID(); let name: String; let tokens: Int }

    /// The day's per-model Codex token receipt, from the History series' last (today) bucket,
    /// filtered to Codex model ids (gpt-*/codex-*). Reuses the precomputed per-day maps.
    private var todayByModelList: [ModelTok] {
        guard let today = snapshot.history.last else { return [] }
        return today.tokensByModel
            .filter { $0.value > 0 && isCodexModel($0.key) }
            .sorted { $0.value > $1.value }
            .map { ModelTok(name: prettyModel($0.key), tokens: $0.value) }
    }

    private func isCodexModel(_ base: String) -> Bool {
        let id = base.lowercased()
        return id.contains("codex") || id.hasPrefix("gpt")
    }

    private func prettyModel(_ base: String) -> String {
        if base.isEmpty || base.lowercased() == "<codex-unknown>" { return "Other" }
        return Fmt.modelName(base)
    }

    @ViewBuilder private var todayByModelRows: some View {
        let rows = Array(todayByModelList.prefix(4))
        if rows.isEmpty {
            Text("No Codex usage yet today").font(.system(size: 11)).foregroundStyle(Theme.faint)
        } else {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, m in
                HStack(spacing: 9) {
                    Circle().fill(accent.opacity(i == 0 ? 1 : 0.6)).frame(width: 7, height: 7)
                    Text(m.name).font(.system(size: 12)).foregroundStyle(Theme.ink)
                    Spacer(minLength: 8)
                    Text(Fmt.abbrev(m.tokens)).font(Theme.figure(12, weight: .regular))
                        .foregroundStyle(Theme.muted).frame(width: 54, alignment: .trailing)
                }
            }
        }
    }
}
