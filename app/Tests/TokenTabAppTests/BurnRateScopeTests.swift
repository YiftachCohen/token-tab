// Burn-rate scoping — the "tok/hr" and "$/hr" figures, and the two pace projections
// built on them.
//
// `agg.lastHourTokens` / `agg.cost.lastHour` are every provider's trailing hour added
// together. Both places that display a rate sit under a Claude heading — BurnPanel's
// BURN RATE / ≈ COST / HR card and SubscriptionPanel's 5-HOUR SESSION "Trend" row — and
// SubscriptionPanel's pace line goes further and measures the rate against Claude's own
// 5h cap, so a busy Codex hour spends Claude's headroom on paper. That is the same
// DESIGN.md 2026-07-31 rule the "BURNED TODAY" hero was fixed for: a figure the UI labels
// as one provider's must come from that provider's records alone.
//
// The aggregation itself is proven in both engines by test/fixtures/parity/
// last-hour-burn-rate.json; what's pinned here is the accessor the views read.

import XCTest
@testable import TokenTab
@testable import TokenTabCore

final class BurnRateScopeTests: XCTestCase {

    /// Claude burned 420K/$1.50 in the last hour, Codex 300K/$1.75 — so the combined
    /// figures (720K/$3.25) overstate Claude's pace by 71%.
    private func mixedSnapshot() -> Snapshot {
        var snap = Snapshot.empty
        snap.agg.lastHourTokens = 720_000
        var combined = CostSummary()
        combined.lastHour = 3.25
        combined.today = 12.0
        snap.agg.cost = combined

        var claude = ProviderSubtotal()
        claude.total = 570_000
        claude.lastHour = 420_000
        var claudeCost = ProviderCost()
        claudeCost.lastHour = 1.50
        claudeCost.today = 6.0
        claude.cost = claudeCost
        snap.agg.providers["claude"] = claude

        var codex = ProviderSubtotal()
        codex.total = 300_000
        codex.lastHour = 300_000
        var codexCost = ProviderCost()
        codexCost.lastHour = 1.75
        codexCost.today = 6.0
        codex.cost = codexCost
        snap.agg.providers["codex"] = codex
        return snap
    }

    func testBurnRateIsClaudesOwnNotTheCombinedTotal() {
        let snap = mixedSnapshot()
        XCTAssertEqual(snap.claudeLastHourTokens, 420_000,
                       "the trend/burn-rate figure must not carry Codex's hour")
        XCTAssertEqual(snap.claudeCostLastHour, 1.50, accuracy: 1e-9,
                       "the $/hr figure must not carry Codex's hour")
        // The combined values are still there for anything that genuinely means "everything".
        XCTAssertEqual(snap.agg.lastHourTokens, 720_000)
        XCTAssertEqual(snap.agg.cost?.lastHour ?? 0, 3.25, accuracy: 1e-9)
    }

    /// A Claude-only aggregate from before per-provider subtotals existed: there the
    /// combined figure IS Claude's, so the fallback must return it rather than zero — the
    /// same rule `claudeCostToday` and `claudeHasUsage` follow.
    func testLegacyAggregateFallsBackToTheCombinedFigure() {
        var legacy = Snapshot.empty
        legacy.agg.lastHourTokens = 250_000
        var cost = CostSummary()
        cost.lastHour = 0.75
        legacy.agg.cost = cost

        XCTAssertEqual(legacy.claudeLastHourTokens, 250_000)
        XCTAssertEqual(legacy.claudeCostLastHour, 0.75, accuracy: 1e-9)
    }

    /// An idle meter reads zero, not nil-shaped garbage — the pace lines gate on `> 0`,
    /// so this is what keeps a cold aggregate from projecting a forecast.
    func testEmptySnapshotHasNoBurnRate() {
        XCTAssertEqual(Snapshot.empty.claudeLastHourTokens, 0)
        XCTAssertEqual(Snapshot.empty.claudeCostLastHour, 0, accuracy: 1e-9)
    }

    /// Codex-only traffic must leave Claude's rate at zero. This is the case the combined
    /// figure got wrong in the worst way: no Claude activity at all, yet SubscriptionPanel
    /// would price Codex's hour against Claude's cap and warn about a heavy pace.
    func testCodexOnlyTrafficLeavesClaudesRateAtZero() {
        var snap = Snapshot.empty
        snap.agg.lastHourTokens = 300_000
        var combined = CostSummary()
        combined.lastHour = 1.75
        snap.agg.cost = combined

        var claude = ProviderSubtotal()          // present, but idle this hour
        claude.total = 570_000
        claude.cost = ProviderCost()
        snap.agg.providers["claude"] = claude

        var codex = ProviderSubtotal()
        codex.total = 300_000
        codex.lastHour = 300_000
        var codexCost = ProviderCost()
        codexCost.lastHour = 1.75
        codex.cost = codexCost
        snap.agg.providers["codex"] = codex

        XCTAssertEqual(snap.claudeLastHourTokens, 0)
        XCTAssertEqual(snap.claudeCostLastHour, 0, accuracy: 1e-9)
    }
}
