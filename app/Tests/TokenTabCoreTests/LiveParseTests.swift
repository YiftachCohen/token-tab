// Golden-fixture tests for the live-usage parser — ported from
// ../../test/live-parse.test.mjs. Same fixtures, same expectations, so the native port
// stays in parity with the audited JS engine.
//
// Pure-parser only: we NEVER spawn `claude` here. The fixtures are the exact strings
// `claude -p "/usage" --output-format json` prints (the `·` is U+00B7). Each case pins
// a failure mode the /autoplan eng review flagged.

import XCTest
@testable import TokenTabCore

private func envelope(_ result: String, isError: Bool = false) -> String {
    let obj: [String: Any] = [
        "type": "result",
        "is_error": isError,
        "result": result,
        "total_cost_usd": 0,
        "usage": ["input_tokens": 0, "output_tokens": 0],
    ]
    let data = try! JSONSerialization.data(withJSONObject: obj)
    return String(data: data, encoding: .utf8)!
}

private let ACTIVE = [
    "You are currently using your subscription to power your Claude Code usage",
    "",
    "Current session: 7% used \u{00B7} resets Jun 21 at 9:49pm (Europe/Rome)",
    "Current week (all models): 8% used \u{00B7} resets Jun 27 at 6:59am (Europe/Rome)",
    "Current week (Sonnet only): 0% used",
    "",
    "What's contributing to your limits usage?",
    "Approximate, based on local sessions on this machine — does not include other devices or claude.ai.",
].joined(separator: "\n")

final class LiveParseTests: XCTestCase {

    func testActiveFixtureSessionWeeklyPerModel() {
        let a = LiveParse.parseUsageOutput(envelope(ACTIVE))
        XCTAssertEqual(a?.sessionPct, 7)
        XCTAssertEqual(a?.sessionResetText, "Jun 21 at 9:49pm (Europe/Rome)")
        XCTAssertEqual(a?.weeklyPct, 8)
        XCTAssertEqual(a?.weeklyResetText, "Jun 27 at 6:59am (Europe/Rome)")
        XCTAssertEqual(a?.weeklyByModel, ["sonnet": 0])
    }

    func testIsErrorTrueEnvelopeIsNil() {
        XCTAssertNil(LiveParse.parseUsageOutput(envelope(ACTIVE, isError: true)))
    }

    func testNonJSONStdoutIsNil() {
        XCTAssertNil(LiveParse.parseUsageOutput("command not found: claude"))
    }

    func testValidJSONNoUsageLinesIsNil() {
        XCTAssertNil(LiveParse.parseUsageOutput(envelope("just some prose, no current usage here")))
    }

    func testEmptyStringIsNil() {
        XCTAssertNil(LiveParse.parseUsageOutput(""))
    }

    func testNilInputIsNilAndDoesNotThrow() {
        XCTAssertNil(LiveParse.parseUsageOutput(nil))
    }

    func testIdleSessionNoResetsTailPctParsedResetTextNil() {
        let a = LiveParse.parseUsageOutput(envelope("Current session: 3% used"))
        XCTAssertEqual(a?.sessionPct, 3)
        XCTAssertNil(a?.sessionResetText)
    }

    func testSeparatorDriftDotToHyphenPercentageStillParses() {
        // The whole point of two-regex parsing: a separator change must not kill the %.
        let drift = ACTIVE.replacingOccurrences(of: "\u{00B7}", with: "-")
        let a = LiveParse.parseUsageOutput(envelope(drift))
        XCTAssertEqual(a?.sessionPct, 7, "% survives a separator change")
        XCTAssertEqual(a?.weeklyPct, 8)
    }

    func testUnrecognizedTailNoResetsWordPctSurvivesResetTextNil() {
        let a = LiveParse.parseUsageOutput(envelope("Current session: 7% used until tomorrow"))
        XCTAssertEqual(a?.sessionPct, 7)
        XCTAssertNil(a?.sessionResetText)
    }

    func testAllModelsFillsWeeklyPctAndNeverLeaksIntoWeeklyByModel() {
        let a = LiveParse.parseUsageOutput(envelope(ACTIVE))
        XCTAssertEqual(a?.weeklyPct, 8)
        XCTAssertNil(a?.weeklyByModel["all models"])
        XCTAssertEqual(Array((a?.weeklyByModel ?? [:]).keys), ["sonnet"])
    }

    func testOnlyIsStrippedAndLowercased() {
        let a = LiveParse.parseUsageOutput(envelope("Current week (Sonnet only): 4% used"))
        XCTAssertEqual(a?.weeklyByModel, ["sonnet": 4])
        XCTAssertNil(a?.weeklyByModel["sonnet only"])
    }

    func testMultiplePerModelWeekliesSonnetAndOpus() {
        let result = [
            "Current week (all models): 8% used \u{00B7} resets Jun 27 at 6:59am (Europe/Rome)",
            "Current week (Sonnet only): 0% used",
            "Current week (Opus only): 12% used",
        ].joined(separator: "\n")
        let a = LiveParse.parseUsageOutput(envelope(result))
        XCTAssertEqual(a?.weeklyByModel, ["sonnet": 0, "opus": 12])
        XCTAssertEqual(a?.weeklyPct, 8)
    }

    func testCRLFLineEndingsParseIdentically() {
        let a = LiveParse.parseUsageOutput(envelope(ACTIVE.replacingOccurrences(of: "\n", with: "\r\n")))
        XCTAssertEqual(a?.sessionPct, 7)
        XCTAssertEqual(a?.sessionResetText, "Jun 21 at 9:49pm (Europe/Rome)", "no trailing \\r in reset text")
        XCTAssertEqual(a?.weeklyByModel, ["sonnet": 0])
    }

    func testOverLimitPercentageParsesNotClamped() {
        let a = LiveParse.parseUsageOutput(envelope("Current session: 103% used \u{00B7} resets soon"))
        XCTAssertEqual(a?.sessionPct, 103)
    }

    func testSessionAbsentButWeeklyPresent() {
        let a = LiveParse.parseUsageOutput(
            envelope("Current week (all models): 8% used \u{00B7} resets Jun 27 at 6:59am (Europe/Rome)"))
        XCTAssertEqual(a?.weeklyPct, 8)
        XCTAssertNil(a?.sessionPct)
    }

    func testWeeklyAbsentButSessionPresent() {
        let a = LiveParse.parseUsageOutput(
            envelope("Current session: 7% used \u{00B7} resets Jun 21 at 9:49pm (Europe/Rome)"))
        XCTAssertEqual(a?.sessionPct, 7)
        XCTAssertNil(a?.weeklyPct)
        XCTAssertEqual(a?.weeklyByModel, [:])
    }
}
