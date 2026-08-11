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

    // MARK: - A REAL Codex-only aggregate (no hand-placed Claude bucket)

    /// The case above is hand-built and inserts an idle Claude bucket, which real
    /// aggregation never produces: buckets are created per record, so a user with Codex
    /// logs and no Claude logs gets `providers == ["codex"]` and NO Claude key at all.
    /// Every `claude*` accessor then hit its legacy fallback and returned the COMBINED
    /// figures — which are entirely Codex's. So the fixture here is the genuine article,
    /// built by `aggregate()` from Codex records only.
    private func codexOnlyAggregate(now: Date) -> Aggregate {
        let rec = UsageRecord(messageId: "codex:s1", requestId: "token:0", model: "gpt-5.2-codex",
                              usage: TokenUsage(input: 200_000, output: 100_000),
                              timestamp: now.addingTimeInterval(-20 * 60),
                              isSidechain: false, provider: "codex")
        return aggregate([rec], options: AggregateOptions(now: now), costModel: Pricing())
    }

    /// `today` keys off the LOCAL calendar day, so a test that pins it has to fix the zone or
    /// it passes only where the tester happens to live: `now` here is 08:00Z, which in Los
    /// Angeles is 00:00 local, putting a record 20 minutes earlier on the previous day.
    /// Same rule the parity fixtures follow — pin calendar fields only where the zone is known.
    private func withTimeZone(_ id: String, _ body: () -> Void) {
        let saved = getenv("TZ").map { String(cString: $0) }
        setenv("TZ", id, 1)
        NSTimeZone.resetSystemTimeZone()
        defer {
            if let saved { setenv("TZ", saved, 1) } else { unsetenv("TZ") }
            NSTimeZone.resetSystemTimeZone()
        }
        // Compare offsets, not identifiers: Foundation reports TZ=UTC as "GMT". Checking at
        // all still matters — assigning NSTimeZone.default silently does nothing here, so a
        // zone-pinned test can otherwise run in the machine's own zone and prove nothing.
        let ref = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(TimeZone.current.secondsFromGMT(for: ref),
                       TimeZone(identifier: id)?.secondsFromGMT(for: ref),
                       "the zone override did not take (got \(TimeZone.current.identifier))")
        body()
    }

    func testRealCodexOnlyAggregateHasNoClaudeBucketAndReportsClaudeAsZero() {
        withTimeZone("UTC") {
        let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15T08:00:00Z
        var snap = Snapshot.empty
        snap.agg = codexOnlyAggregate(now: now)

        // Precondition — this is what makes the fallback fire, and what the hand-built
        // test above accidentally papered over.
        XCTAssertNil(snap.agg.providers["claude"], "real Codex-only aggregation makes no Claude bucket")
        XCTAssertEqual(snap.agg.today, 300_000, "the COMBINED figures are all Codex's")
        XCTAssertGreaterThan(snap.agg.cost?.today ?? 0, 0)

        XCTAssertEqual(snap.claudeToday, 0, "Codex's tokens must not be reported as Claude's")
        XCTAssertEqual(snap.claudeCostToday, 0, accuracy: 1e-9, "nor Codex's dollars")
        XCTAssertEqual(snap.claudeLastHourTokens, 0)
        XCTAssertEqual(snap.claudeCostLastHour, 0, accuracy: 1e-9)
        XCTAssertFalse(snap.claudeHasUsage, "there is no Claude usage to show")
        XCTAssertTrue(snap.codexHasUsage)
        }
    }

    /// The consequence that reaches the screen: with no official Codex window to compare
    /// (absent, or expired), `headlineProvider` falls through to today-tokens. While Claude's
    /// figure was the combined total it tied with Codex's own and `.claude` won the
    /// comparison — so a Codex-only user got a Claude-labelled panel showing Codex usage.
    ///
    /// Asserted in two zones deliberately. In UTC the record IS today, which exercises the
    /// token comparison. In Los Angeles the same instant lands on the previous local day, so
    /// both sides are 0 and the comparison ties — and a tie used to go to Claude, meaning a
    /// Codex-only user got a Claude panel every morning until they next ran Codex. Scoping
    /// the accessors alone does not fix that; the has-usage precedence does.
    func testCodexOnlyUsageHeadlinesCodexWhenNoOfficialWindowExists() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for zone in ["UTC", "America/Los_Angeles"] {
            withTimeZone(zone) {
                var snap = Snapshot.empty
                snap.agg = codexOnlyAggregate(now: now)
                XCTAssertNil(snap.codexDisplayWindow, "this is the no-official-%, tokens-decide path")
                XCTAssertEqual(snap.headlineProvider(now: now), .codex,
                               "the only provider with usage must headline (\(zone))")
            }
        }
        // And the tie really is a tie in Los Angeles — otherwise the case above would be
        // passing for the wrong reason.
        withTimeZone("America/Los_Angeles") {
            var snap = Snapshot.empty
            snap.agg = codexOnlyAggregate(now: now)
            XCTAssertEqual(snap.agg.today, 0, "the record falls on the previous local day here")
        }
    }

    /// The fallback still has to work for what it was written for: an aggregate from before
    /// per-provider subtotals existed carries NO buckets, and there the combined block IS
    /// Claude's. That is the one case where reading it as Claude's is correct.
    func testLegacyNoBucketAggregateStillReadsAsClaude() {
        var legacy = Snapshot.empty
        legacy.agg.total = 1_000
        legacy.agg.today = 800
        legacy.agg.lastHourTokens = 250_000
        var cost = CostSummary()
        cost.today = 4.0
        cost.lastHour = 0.75
        legacy.agg.cost = cost

        XCTAssertTrue(legacy.agg.providers.isEmpty, "the precondition: no buckets at all")
        XCTAssertTrue(legacy.claudeHasUsage)
        XCTAssertEqual(legacy.claudeToday, 800)
        XCTAssertEqual(legacy.claudeCostToday, 4.0, accuracy: 1e-9)
        XCTAssertEqual(legacy.claudeLastHourTokens, 250_000)
        XCTAssertEqual(legacy.claudeCostLastHour, 0.75, accuracy: 1e-9)
    }
}
