// Menu-bar label tests — the first coverage this view has had.
//
// The label is where two DESIGN.md rows actually live (both dated 2026-07-30): every menu-bar
// percentage is "% LEFT" for both providers, and `.both` puts a glyph+figure pair per provider
// in the bar with Claude first. Those are decisions about exact strings and about ring-vs-dot,
// so they're pinned here rather than left to a visual check — a silent flip back to Codex's
// native "% used" would put a 92%-full ring next to the figure "8%" again.
//
// Snapshots are built by hand (no log fixtures): these are pure display rules over an
// already-aggregated Snapshot, and the aggregation itself is covered by CoreTests/ParityTests.

import XCTest
import AppKit
@testable import TokenTab
@testable import TokenTabCore

final class MenuBarLabelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A Claude subtotal with usage. `capTokens`/`cap` give Claude a REAL quota % (the only
    /// basis that makes `quotaLeft` non-nil without a live reading).
    private func snapshot(claudeToday: Int = 5_000_000,
                          claudeTotal: Int? = nil,
                          windowTokens: Int = 0,
                          cap: Int = 0,
                          windowActive: Bool = false,
                          codexToday: Int? = nil,
                          codexUsedPct: Double? = nil,
                          codexResetsIn: TimeInterval = 7200,
                          mode: Mode = .subscription) -> Snapshot {
        var snap = Snapshot.empty
        snap.mode = mode
        snap.agg.today = claudeToday
        snap.agg.total = claudeTotal ?? claudeToday
        snap.agg.window = WindowStats(active: windowActive, tokens: windowTokens,
                                      resetAt: windowActive ? now.addingTimeInterval(3600) : nil,
                                      blockSeconds: 5 * 3600, cap: cap, calibratedCap: 0)
        if claudeToday > 0 || (claudeTotal ?? 0) > 0 {
            var claude = ProviderSubtotal()
            claude.today = claudeToday
            claude.total = claudeTotal ?? claudeToday
            snap.agg.providers["claude"] = claude
        }
        if codexToday != nil || codexUsedPct != nil {
            var codex = ProviderSubtotal()
            codex.today = codexToday ?? 0
            codex.total = codexToday ?? 1            // "has usage" even when today is 0
            if let used = codexUsedPct {
                codex.windows["primary"] = ProviderWindow(source: "official", period: "5h",
                                                          resetAt: now.addingTimeInterval(codexResetsIn),
                                                          usedPct: used, windowMinutes: 300)
            }
            snap.agg.providers["codex"] = codex
        }
        return snap
    }

    private func label(_ snap: Snapshot, scope: MenuBarScope = .both,
                       metric: MenuMetric = .cost) -> MenuBarLabel {
        MenuBarLabel(snapshot: snap, menuMetric: metric, scope: scope, now: now)
    }

    // MARK: - "% left", both providers, both scopes

    /// The regression this whole change exists to prevent: Codex's official reading is
    /// natively "% used", and the menu bar must invert it. 8% spent ⇒ "92%", never "8%".
    func testCodexFigureIsPercentLeftNotUsed() {
        let snap = snapshot(codexToday: 1_000_000, codexUsedPct: 8)
        XCTAssertEqual(label(snap).codexFigure, "92%")
        // …and the single-glyph label agrees, with the suffix that identifies it.
        let codexHeadline = snapshot(claudeToday: 1, codexToday: 9_000_000, codexUsedPct: 8)
        XCTAssertEqual(label(codexHeadline, scope: .headline).text, "92% Cdx")
    }

    /// Claude's quota figure is already "% left"; assert both providers now read the same
    /// direction, which is the precondition for showing them side by side at all.
    func testBothProvidersReadPercentLeftInTheSameDirection() {
        // cap 10M, 3M used ⇒ 70% left. Codex 8% used ⇒ 92% left.
        let snap = snapshot(windowTokens: 3_000_000, cap: 10_000_000, windowActive: true,
                            codexToday: 1_000_000, codexUsedPct: 8)
        let l = label(snap)
        XCTAssertTrue(l.showsBoth)
        XCTAssertEqual(l.claudeFigure, "70%")
        XCTAssertEqual(l.codexFigure, "92%")
    }

    // MARK: - When the dual label engages

    func testDualLabelOnlyWhenBothProvidersHaveUsage() {
        // Claude only → single label, byte-identical to `.headline`.
        let claudeOnly = snapshot(claudeToday: 5_000_000)
        XCTAssertFalse(label(claudeOnly).showsBoth)
        XCTAssertEqual(label(claudeOnly).text, label(claudeOnly, scope: .headline).text)

        // Codex only → still single.
        let codexOnly = snapshot(claudeToday: 0, claudeTotal: 0, codexToday: 2_000_000, codexUsedPct: 30)
        XCTAssertFalse(label(codexOnly).showsBoth)

        // Both → dual.
        XCTAssertTrue(label(snapshot(codexToday: 2_000_000, codexUsedPct: 30)).showsBoth)
    }

    func testHeadlineScopeNeverShowsBoth() {
        let snap = snapshot(codexToday: 2_000_000, codexUsedPct: 30)
        XCTAssertFalse(label(snap, scope: .headline).showsBoth)
    }

    // MARK: - Honest fallbacks

    /// A ring asserts "I know a percentage". Codex with usage but no rate-limits reading has
    /// none, so it must get the 8pt dot, not a ring — and its figure falls back to tokens.
    func testCodexWithoutOfficialReadingGetsDotAndTokens() {
        let snap = snapshot(codexToday: 1_500_000, codexUsedPct: nil)
        let l = label(snap)
        XCTAssertEqual(l.codexFigure, "1.5M")
        XCTAssertEqual(l.codexGlyph.size.width, 8, "no official % ⇒ dot, never a ring")

        let withPct = label(snapshot(codexToday: 1_500_000, codexUsedPct: 8))
        XCTAssertEqual(withPct.codexGlyph.size.width, 13, "official % ⇒ the indigo ring")
    }

    /// In dual mode Claude's token fallback must be Claude's OWN tokens. The single label
    /// deliberately shows the COMBINED total there (one figure for the whole Mac), and
    /// reusing that in a two-pair label would count Codex's usage twice.
    func testDualClaudeTokenFallbackExcludesCodex() {
        var snap = snapshot(claudeToday: 4_000_000, codexToday: 6_000_000, codexUsedPct: nil)
        snap.agg.today = 10_000_000   // combined, as aggregate() reports it
        let l = label(snap)
        XCTAssertEqual(l.claudeFigure, "4.0M", "Claude's own today, not the 10M combined")
        XCTAssertEqual(l.codexFigure, "6.0M")
        // The single label keeps its combined-total behavior.
        XCTAssertEqual(label(snap, scope: .headline).text, "10.0M")
    }

    /// No quota basis anywhere: Claude is honest about being a clock, not a percentage.
    func testDualClaudeFallsBackToTimeLeftWhenNoQuotaBasis() {
        let snap = snapshot(windowTokens: 3_000_000, cap: 0, windowActive: true,
                            codexToday: 1_000_000, codexUsedPct: 8)
        XCTAssertEqual(label(snap).claudeFigure, "1h00", "no cap ⇒ the time countdown")
    }

    func testDualBurnModeUsesTheMenuMetric() {
        var snap = snapshot(claudeToday: 4_000_000, codexToday: 1_000_000,
                            codexUsedPct: 8, mode: .burn)
        // Combined spend is $12.50, of which only $9.00 is Claude's — the Claude-positioned
        // pair must show Claude's own, exactly as its token fallback does.
        var cost = CostSummary()
        cost.today = 12.5
        snap.agg.cost = cost
        var claudeCost = ProviderCost()
        claudeCost.today = 9
        snap.agg.providers["claude"]?.cost = claudeCost
        var codexCost = ProviderCost()
        codexCost.today = 3.5
        snap.agg.providers["codex"]?.cost = codexCost

        XCTAssertEqual(label(snap, metric: .cost).claudeFigure, "$9.00",
                       "Claude's own spend, not the $12.50 combined")
        XCTAssertEqual(label(snap, metric: .tokens).claudeFigure, "4.0M")
        XCTAssertEqual(label(snap, metric: .cost).claudeGlyph.size.width, 8, "burn ⇒ health dot")
    }

    /// A snapshot with no per-provider cost block (pre-provider aggregates, and any
    /// aggregate built without a cost model) still reads the combined total — there,
    /// combined IS Claude-only, so the fallback is correct rather than merely safe.
    func testDualClaudeCostFallsBackToCombinedWhenNoProviderCostBlock() {
        var snap = snapshot(claudeToday: 4_000_000, codexToday: 1_000_000,
                            codexUsedPct: 8, mode: .burn)
        var cost = CostSummary()
        cost.today = 12.5
        snap.agg.cost = cost
        XCTAssertNil(snap.agg.providers["claude"]?.cost)
        XCTAssertEqual(label(snap, metric: .cost).claudeFigure, "$12.50")
    }

    // MARK: - An expired official window is not a percentage any more

    /// Codex only writes logs while it runs, so the last snapshot sits on disk forever. Once
    /// its recorded window has reset, the number describes a DIFFERENT window (OpenAI restarts
    /// the new one at 0%) — so it must stop being a percentage everywhere at once: no headline,
    /// no ring, no figure. Otherwise a machine that used Codex last week keeps a nearly-full
    /// indigo ring in the menu bar indefinitely.
    func testExpiredCodexWindowStopsBeingAPercentage() {
        // Claude out-volumes Codex on tokens, so once Codex's % stops counting the ranking
        // falls through to today-tokens and Claude takes the headline. That isolates the
        // expiry: nothing but the reset time differs between the two snapshots below.
        let expired = snapshot(claudeToday: 20_000_000, codexToday: 9_000_000,
                               codexUsedPct: 92, codexResetsIn: -60)
        XCTAssertTrue(expired.codexWindowExpired(now: now))
        XCTAssertNil(expired.codexUsedPct(now: now))
        XCTAssertNil(expired.codexLeftPct(now: now))

        let l = label(expired)
        XCTAssertEqual(l.codexFigure, "9.0M", "no current %, so the figure falls back to tokens")
        XCTAssertEqual(l.codexGlyph.size.width, 8, "no current % ⇒ dot, never a ring")

        // …and it must not win the headline on the strength of a window that already reset.
        XCTAssertEqual(expired.headlineProvider(now: now), .claude)
        XCTAssertFalse(label(expired, scope: .headline).text.contains("Cdx"))

        // The same snapshot one minute BEFORE its reset still counts, so this is the expiry
        // doing the work, not the fallback swallowing every Codex reading.
        let current = snapshot(claudeToday: 20_000_000, codexToday: 9_000_000,
                               codexUsedPct: 92, codexResetsIn: 60)
        XCTAssertEqual(current.codexUsedPct(now: now), 92)
        XCTAssertEqual(current.headlineProvider(now: now), .codex)
        XCTAssertEqual(label(current, scope: .headline).text, "8% Cdx")
        XCTAssertEqual(label(current).codexGlyph.size.width, 13, "current % ⇒ the indigo ring")
    }

    /// A snapshot with no recorded resetAt can't be judged expired — there's nothing to
    /// compare against — so it keeps its reading (codexStale is what flags those).
    func testCodexWindowWithoutResetAtIsNotTreatedAsExpired() {
        var snap = snapshot(codexToday: 1_000_000, codexUsedPct: 8)
        snap.agg.providers["codex"]?.windows["primary"] =
            ProviderWindow(source: "official", period: "5h", usedPct: 8, windowMinutes: 300)
        XCTAssertFalse(snap.codexWindowExpired(now: now))
        XCTAssertEqual(snap.codexUsedPct(now: now), 8)
    }

    /// Current Codex logs may put a weekly-only limit in the raw `primary` slot. After core
    /// normalization that arrives here as `secondary`; the panel may display it, but the
    /// max-pressure/menu-bar helpers must not compare a weekly percentage to Claude's 5h %.
    func testWeeklyOnlyWindowIsDisplayableWithoutMasqueradingAsFiveHourPressure() {
        var snap = snapshot(claudeToday: 20_000_000, codexToday: 9_000_000)
        snap.agg.providers["codex"]?.windows["secondary"] =
            ProviderWindow(source: "official", period: "weekly",
                           resetAt: now.addingTimeInterval(6 * 24 * 3600),
                           usedPct: 57, windowMinutes: 10080)

        XCTAssertNil(snap.codexPrimary)
        XCTAssertEqual(snap.codexDisplayWindow?.period, "weekly")
        XCTAssertEqual(snap.codexDisplayUsedPct(now: now), 57)
        XCTAssertEqual(snap.codexDisplayLeftPct(now: now), 43)
        XCTAssertNil(snap.codexUsedPct(now: now), "weekly usage is not a comparable 5h pressure")
        XCTAssertEqual(snap.headlineProvider(now: now), .claude,
                       "without a 5h Codex reading, ranking falls back to provider tokens")
    }

    // MARK: - The usage predicates the dual label gates on

    func testProviderUsagePredicates() {
        XCTAssertFalse(Snapshot.empty.claudeHasUsage)
        XCTAssertFalse(Snapshot.empty.codexHasUsage)
        XCTAssertFalse(Snapshot.empty.bothProvidersHaveUsage)

        let both = snapshot(codexToday: 1, codexUsedPct: 8)
        XCTAssertTrue(both.claudeHasUsage)
        XCTAssertTrue(both.codexHasUsage)
        XCTAssertTrue(both.bothProvidersHaveUsage)

        // A Claude-only aggregate with no per-provider subtotal still counts as usage
        // (the overall-total fallback), so pre-provider snapshots don't read as empty.
        var legacy = Snapshot.empty
        legacy.agg.total = 1_000
        XCTAssertTrue(legacy.claudeHasUsage)
        XCTAssertFalse(legacy.bothProvidersHaveUsage)
    }
}
