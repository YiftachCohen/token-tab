// Token Tab — staged data for the shot renderer.
//
// Marketing images must never be photographs of the author's real Mac: a real snapshot leaks
// project names through the log paths, shows whatever numbers the day happened to produce, and
// can't be re-shot identically after a redesign. So every shot is driven by a Snapshot built
// here — the same hand-built-Snapshot technique MenuBarLabelTests uses, sized up to fill a
// whole panel.
//
// Deterministic by construction: the day-to-day variation comes from a fixed-seed LCG, not
// Math.random, so re-running the renderer reproduces the same bars. The only moving part is
// the calendar — the History series has to END on today's date or the panel's "today" bucket
// (which feeds the by-model receipt) lands in the past.

import Foundation
@testable import TokenTab
@testable import TokenTabCore

enum ShotFixtures {

    // MARK: - The scenes' snapshots

    /// Claude Max, mid-window, comfortably inside the quota — the hero shot. A live reading
    /// makes the header show the pulsing LIVE dot (the "this % is authoritative" affordance).
    static func subscription(now: Date = Date()) -> Snapshot {
        var agg = Aggregate()
        agg.today = 18_400_000
        agg.total = 1_284_000_000
        agg.thisWeek = 96_200_000
        agg.lastHourTokens = 2_450_000
        agg.byModel = ["claude-opus-4-5": 812_000_000,
                       "claude-sonnet-4-5": 401_000_000,
                       "claude-haiku-4-5": 71_000_000]
        agg.window = WindowStats(active: true, tokens: 8_600_000,
                                 resetAt: now.addingTimeInterval(2 * 3600 + 12 * 60),
                                 blockSeconds: 5 * 3600, cap: 20_000_000, calibratedCap: 19_400_000)
        var claude = ProviderSubtotal()
        claude.today = agg.today
        claude.total = agg.total
        claude.thisWeek = agg.thisWeek
        claude.byModel = agg.byModel
        agg.providers["claude"] = claude
        agg.providerOrder = ["claude"]

        var snap = Snapshot(agg: agg, mode: .subscription, surface: .subscription, health: .healthy,
                            fileCount: 213, malformed: 0, lastUpdated: now.addingTimeInterval(-8),
                            cap: 20_000_000,
                            live: LiveUsage(sessionPct: 43, sessionResetText: "2h 12m",
                                            weeklyPct: 31, weeklyResetText: "Mon 09:00",
                                            capturedAt: now.addingTimeInterval(-40)),
                            history: [])
        snap.history = history(now: now, todayTokens: agg.today, mode: .subscription)
        return snap
    }

    /// Pay-per-token (Bedrock / API): the meter is running, so dollars lead and everything
    /// turns amber. Costs are the fixture's own numbers, not derived from the rate table.
    static func burn(now: Date = Date()) -> Snapshot {
        let todayTokens = 31_800_000
        let series = history(now: now, todayTokens: todayTokens, mode: .burn)

        var cost = CostSummary()
        // The hero reads `cost.today` while the receipt under it is summed from today's
        // History bucket — so the hero is taken FROM that bucket. Picking a round number here
        // instead put a $23.94 headline above rows that added up to $21.16.
        cost.today = series.last?.cost ?? 0
        cost.total = 1_942.60
        cost.thisWeek = 148.30
        cost.rolling5h = 9.12
        cost.lastHour = 2.41
        cost.byModel = ["claude-opus-4-5": 16.20, "claude-sonnet-4-5": 6.10, "claude-haiku-4-5": 1.64]

        var agg = Aggregate()
        agg.today = todayTokens
        agg.total = 2_640_000_000
        agg.thisWeek = 214_000_000
        agg.lastHourTokens = 3_180_000
        agg.byModel = ["claude-opus-4-5": 1_410_000_000,
                       "claude-sonnet-4-5": 986_000_000,
                       "claude-haiku-4-5": 244_000_000]
        agg.bySurface = [.bedrock: agg.total]
        agg.cost = cost
        agg.split = MainSubSplit(mainTokens: 1_910_000_000, subTokens: 730_000_000,
                                 mainCost: 1_402.10, subCost: 540.50)
        agg.todaySplit = MainSubSplit(mainTokens: 22_600_000, subTokens: 9_200_000,
                                      mainCost: 17.02, subCost: 6.92)
        var claude = ProviderSubtotal()
        claude.today = agg.today
        claude.total = agg.total
        claude.byModel = agg.byModel
        claude.bySurface = agg.bySurface
        agg.providers["claude"] = claude
        agg.providerOrder = ["claude"]

        var snap = Snapshot(agg: agg, mode: .burn, surface: .bedrock, health: .neutral,
                            fileCount: 341, malformed: 0, lastUpdated: now.addingTimeInterval(-14),
                            cap: 0, live: nil, history: [])
        snap.history = series
        return snap
    }

    /// Both providers in use: Codex under real 5h pressure (so it takes the hero gauge and the
    /// indigo pill) with Claude beneath it as the secondary hairline row.
    static func dualProvider(now: Date = Date()) -> Snapshot {
        var snap = subscription(now: now)
        snap.live = nil                       // one authoritative % on screen is enough
        var codex = ProviderSubtotal()
        codex.today = 7_900_000
        codex.total = 184_000_000
        codex.thisWeek = 42_000_000
        codex.rolling5h = 3_140_000
        codex.byModel = ["gpt-5-codex": 154_000_000, "gpt-5-codex-mini": 30_000_000]
        codex.windows["primary"] = ProviderWindow(source: "official", period: "5h",
                                                  resetAt: now.addingTimeInterval(96 * 60),
                                                  usedPct: 68, windowMinutes: 300)
        codex.windows["secondary"] = ProviderWindow(source: "official", period: "weekly",
                                                    resetAt: now.addingTimeInterval(4 * 86_400),
                                                    usedPct: 41, windowMinutes: 10_080)
        codex.plan = CodexPlan(planType: "plus")
        snap.agg.providers["codex"] = codex
        snap.agg.providerOrder = ["claude", "codex"]
        snap.codexFileCount = 64
        // Both panels read their day's receipt out of the History series' LAST bucket, filtered
        // by model id — so a Codex row only appears if Codex models are actually in today's
        // bucket. Add them there rather than to the subtotal alone.
        if var today = snap.history.popLast() {
            today.tokensByModel["gpt-5-codex"] = 6_300_000
            today.tokensByModel["gpt-5-codex-mini"] = 1_600_000
            today.tokens += codex.today
            snap.history.append(today)
        }
        return snap
    }

    // MARK: - History series

    /// A contiguous 60-day series ending TODAY. The panel slices the last 7/14/30 out of this
    /// for the History tab, and reads the final bucket for the Overview's by-model receipt —
    /// so today's bucket is pinned to the aggregate's `today` rather than generated.
    private static func history(now: Date, todayTokens: Int, mode: Mode) -> [DayUsage] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var rng = LCG(seed: 0x7A11_B00C)
        var days: [DayUsage] = []

        for offset in stride(from: 59, through: 0, by: -1) {
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let weekday = cal.component(.weekday, from: date)
            let weekend = weekday == 1 || weekday == 7
            // A working week with a slow ramp over the two months. Weekends are quieter, but
            // not empty: the panel ALSO fades weekend bars, so a low multiplier here compounds
            // with that and the chart reads as missing days rather than light ones.
            let ramp = 0.72 + 0.28 * (Double(59 - offset) / 59)
            let jitter = 0.68 + rng.next() * 0.64
            let base = Double(mode == .burn ? 26_000_000 : 15_500_000)
            var tokens = Int(base * ramp * jitter * (weekend ? 0.45 : 1.0))
            if offset == 0 { tokens = todayTokens }

            // Opus leads, Sonnet carries the bulk of the volume, Haiku is the cheap tail.
            let split: [(String, Double)] = [("claude-opus-4-5", 0.44),
                                             ("claude-sonnet-4-5", 0.41),
                                             ("claude-haiku-4-5", 0.15)]
            var byModel: [String: Int] = [:]
            var costByModel: [String: Double] = [:]
            for (model, share) in split {
                let t = Int(Double(tokens) * share)
                byModel[model] = t
                // Blended $/Mtok per tier — fixture figures, deliberately not the rate table
                // (a shot must not silently become a second source of truth for pricing).
                let perMTok = model.contains("opus") ? 1.10 : model.contains("sonnet") ? 0.42 : 0.06
                costByModel[model] = Double(t) / 1_000_000 * perMTok
            }
            days.append(DayUsage(date: date, tokens: tokens,
                                 cost: costByModel.values.reduce(0, +), weekend: weekend,
                                 tokensByModel: byModel, costByModel: costByModel))
        }
        return days
    }

    /// A tiny deterministic generator — the bars must be identical from run to run, and
    /// `Math.random`-style sources would make every re-shot image a spurious diff.
    private struct LCG {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
    }
}
