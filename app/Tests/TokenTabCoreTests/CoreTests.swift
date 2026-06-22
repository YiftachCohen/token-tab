// Parity tests for the Swift core — ported from ../../test/core.test.mjs.
// Same fixtures, same expected numbers, so the native engine reconciles with the
// audited JS engine (and thus with ccusage). Synthetic values only — no real content.

import XCTest
@testable import TokenTabCore

private func date(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: iso)!
}

private func u(_ i: Int, _ cc: Int, _ cr: Int, _ o: Int) -> TokenUsage {
    TokenUsage(input: i, cacheCreate: cc, cacheRead: cr, output: o)
}

private func rec(messageId: String = "m1", requestId: String? = "r1",
                 model: String = "claude-opus-4-8", usage: TokenUsage = u(10, 20, 30, 5),
                 timestamp: String? = "2026-06-20T12:00:00Z", isSidechain: Bool = false) -> UsageRecord {
    UsageRecord(messageId: messageId, requestId: requestId, model: model, usage: usage,
                timestamp: timestamp.map(date), isSidechain: isSidechain)
}

final class CoreTests: XCTestCase {

    func testUsageSumAllFourClasses() {
        XCTAssertEqual(u(1, 2, 4, 8).sum, 15)
        XCTAssertEqual(TokenUsage().sum, 0)
    }

    func testSingleRecordAggregates() {
        let a = aggregate([rec()])
        XCTAssertEqual(a.total, 65)
        XCTAssertEqual(a.byClass.input, 10)
        XCTAssertEqual(a.byClass.cacheCreate, 20)
        XCTAssertEqual(a.byClass.cacheRead, 30)
        XCTAssertEqual(a.byClass.output, 5)
        XCTAssertEqual(a.bySurface[.subscription], 65)
        XCTAssertEqual(a.byModel["claude-opus-4-8"], 65)
        XCTAssertEqual(a.counted, 1)
    }

    func testDedupKeepLast() {
        let partial = rec(usage: u(5, 1151, 34462, 2))   // 35620
        let final = rec(usage: u(5, 1151, 34462, 227))   // 35845
        let a = aggregate([partial, final])
        XCTAssertEqual(a.counted, 1)
        XCTAssertEqual(a.duplicatesDropped, 1)
        XCTAssertEqual(a.total, 35845, "keep-last: final (larger output) wins")
        XCTAssertEqual(a.byClass.output, 227)
    }

    func testMissingRequestIdAlwaysCounted() {
        let a = aggregate([rec(messageId: "m9", requestId: nil),
                           rec(messageId: "m9", requestId: nil)])
        XCTAssertEqual(a.counted, 2)
        XCTAssertTrue(a.approximate)
    }

    func testSidechainIsRealSpendAndSplits() {
        let a = aggregate([rec(messageId: "m1"),
                           rec(messageId: "m2", requestId: "r2", isSidechain: true)])
        XCTAssertEqual(a.counted, 2)
        XCTAssertEqual(a.total, 130)
        XCTAssertEqual(a.split.mainTokens, 65)
        XCTAssertEqual(a.split.subTokens, 65)
    }

    func testSurfaceRouting() {
        XCTAssertEqual(ModelUtil.classifySurface("claude-opus-4-8"), .subscription)
        XCTAssertEqual(ModelUtil.classifySurface("claude-fable-5"), .subscription)
        XCTAssertEqual(ModelUtil.classifySurface("sonnet"), .subscription)
        XCTAssertEqual(ModelUtil.classifySurface("us.anthropic.claude-3-5-sonnet-20241022-v2:0"), .bedrock)
        XCTAssertEqual(ModelUtil.classifySurface("anthropic.claude-3-haiku-20240307-v1:0"), .bedrock)
        XCTAssertEqual(ModelUtil.classifySurface("<synthetic>"), .untracked)
        XCTAssertEqual(ModelUtil.classifySurface("gpt-5.5"), .untracked)
    }

    func testOneMSuffixNormalizes() {
        let n = ModelUtil.normalize("claude-opus-4-8[1m]")
        XCTAssertEqual(n.base, "claude-opus-4-8")
        XCTAssertTrue(n.oneM)
        XCTAssertEqual(ModelUtil.classifySurface("claude-opus-4-8[1m]"), .subscription)
    }

    func testUnknownModelStillCounts() {
        let a = aggregate([rec(messageId: "mx", requestId: "rx", model: "totally-unknown-model")])
        XCTAssertEqual(a.total, 65)
        XCTAssertEqual(a.bySurface[.untracked], 65)
    }

    func testWindowActiveResetExactNoGuessedPct() {
        let now = date("2026-06-20T18:00:00Z")
        let records = [
            rec(messageId: "y", requestId: "yr", timestamp: "2026-06-19T10:00:00Z", isSidechain: false),
            rec(messageId: "a1", requestId: "ar1", usage: u(200, 0, 0, 0), timestamp: "2026-06-20T16:30:00Z"),
            rec(messageId: "a2", requestId: "ar2", usage: u(100, 0, 0, 0), timestamp: "2026-06-20T17:00:00Z"),
        ]
        let a = aggregate(records, options: AggregateOptions(now: now))
        XCTAssertTrue(a.window.active)
        XCTAssertEqual(a.window.tokens, 300)
        XCTAssertEqual(a.window.calibratedCap, 65)
        XCTAssertNil(a.window.tokenPct, "never invent a % without a cap")
        XCTAssertEqual(a.window.resetAt, date("2026-06-20T21:30:00Z"))
        XCTAssertEqual(a.window.secondsToReset(now: now)!, 3.5 * 3600, accuracy: 0.5)
    }

    func testWindowCapGivesPct() {
        let now = date("2026-06-20T18:00:00Z")
        let records = [
            rec(messageId: "a1", requestId: "ar1", usage: u(200, 0, 0, 0), timestamp: "2026-06-20T16:30:00Z"),
            rec(messageId: "a2", requestId: "ar2", usage: u(100, 0, 0, 0), timestamp: "2026-06-20T17:00:00Z"),
        ]
        let a = aggregate(records, options: AggregateOptions(now: now, cap: 600))
        XCTAssertEqual(a.window.tokenPct, 50)
    }

    func testWindowIdle() {
        let now = date("2026-06-20T18:00:00Z")
        let a = aggregate([rec(messageId: "y", requestId: "yr", usage: u(1000, 0, 0, 0), timestamp: "2026-06-19T10:00:00Z")],
                          options: AggregateOptions(now: now))
        XCTAssertFalse(a.window.active)
        XCTAssertEqual(a.window.tokens, 0)
        XCTAssertNil(a.window.secondsToReset(now: now))
    }

    func testRolling5hHalfOpen() {
        let now = date("2026-06-20T18:00:00Z")
        let within = rec(messageId: "a", requestId: "1", timestamp: "2026-06-20T15:00:00Z")   // 3h ago
        let edgeOut = rec(messageId: "b", requestId: "2", timestamp: "2026-06-20T12:30:00Z")  // 5.5h ago
        let a = aggregate([within, edgeOut], options: AggregateOptions(now: now))
        XCTAssertEqual(a.rolling5h, 65)
        XCTAssertEqual(a.total, 130)
    }

    func testPricingOpus() {
        // opus-4-8: input 5, output 25, cacheWrite 6.25, cacheRead 0.5 (per 1M).
        let (usd, priced) = Pricing().cost(u(10, 20, 30, 5), model: "claude-opus-4-8")
        XCTAssertTrue(priced)
        let expected: Double = (10.0 * 5 + 20.0 * 6.25 + 30.0 * 0.5 + 5.0 * 25) / 1_000_000
        XCTAssertEqual(usd, expected, accuracy: 1e-12)
    }

    func testPricingUnknownUnpriced() {
        let (usd, priced) = Pricing().cost(u(10, 0, 0, 5), model: "gpt-5.5")
        XCTAssertFalse(priced)
        XCTAssertEqual(usd, 0)
    }

    func testBedrockCanonicalizes() {
        XCTAssertEqual(Pricing.canonicalModelId("us.anthropic.claude-opus-4-8-20251101-v1:0"), "claude-opus-4-8")
        XCTAssertEqual(Pricing.canonicalModelId("claude-opus-4-8[1m]"), "claude-opus-4-8")
    }
}
