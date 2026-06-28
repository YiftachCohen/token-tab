// Cross-engine parity suite (Swift side).
//
// Loads the SAME fixtures the JS suite loads (test/fixtures/parity/*.json, via
// test/parity.test.mjs) and asserts the SAME shared-subset numbers. If the Swift and JS
// engines ever disagree on dedup, surface routing, windowing, or pricing, one of the two
// suites goes red — which is the whole point: parity is proven by computation, not by
// hand-copied twin tests (see AGENTS.md). Synthetic values only.
//
// Only the fields a fixture pins in `expect` are asserted (each engine has extra fields
// the other lacks). `today`/`cost.today` key off the LOCAL calendar day, so they are
// pinned only in fixtures where they are timezone-independent (see each fixture's
// `_comment`); here, an absent key is skipped while a JSON `null` for resetMs/pct means
// "expect idle / no pct".

import XCTest
@testable import TokenTabCore

final class ParityTests: XCTestCase {

    /// The shared fixtures live at <repo>/test/fixtures/parity, OUTSIDE the SwiftPM
    /// package, so resolve them relative to this source file rather than via bundled
    /// resources (which would be a separate copy that could silently drift).
    private func fixturesDir() -> URL {
        URL(fileURLWithPath: #filePath)   // .../app/Tests/TokenTabCoreTests/ParityTests.swift
            .deletingLastPathComponent()  // .../TokenTabCoreTests
            .deletingLastPathComponent()  // .../Tests
            .deletingLastPathComponent()  // .../app
            .deletingLastPathComponent()  // .../<repo>
            .appendingPathComponent("test/fixtures/parity")
    }

    // ISO8601 tolerant of fractional and non-fractional seconds (mirrors LogReader).
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return ParityTests.isoFrac.date(from: s) ?? ParityTests.isoNoFrac.date(from: s)
    }

    func testParityFixtures() throws {
        let dir = fixturesDir()
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else {
            // STOP condition: the package was built from a relocated source tree.
            XCTFail("Parity fixtures not found at \(dir.path) — cannot reach the shared test/fixtures/parity via #filePath. Do not hard-code an absolute path; report this.")
            return
        }
        let files = (try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThanOrEqual(files.count, 4, "expected >= 4 parity fixtures, found \(files.count)")

        for file in files {
            let data = try Data(contentsOf: file)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                XCTFail("not a JSON object: \(file.lastPathComponent)"); continue
            }
            let name = (root["name"] as? String) ?? file.lastPathComponent
            XCTContext.runActivity(named: name) { _ in
                assertFixture(root, file: file.lastPathComponent, name: name)
            }
        }
    }

    private func assertFixture(_ root: [String: Any], file: String, name: String) {
        let ctx = "[\(file)] \(name)"

        guard let nowStr = root["now"] as? String, let now = parseDate(nowStr) else {
            XCTFail("missing/invalid `now` \(ctx)"); return
        }
        let cap = (root["cap"] as? Int) ?? 0
        let recordsRaw = (root["records"] as? [[String: Any]]) ?? []
        let records: [UsageRecord] = recordsRaw.map { r in
            let usageD = (r["usage"] as? [String: Any]) ?? [:]
            let usage = TokenUsage(
                input: (usageD["input_tokens"] as? Int) ?? 0,
                cacheCreate: (usageD["cache_creation_input_tokens"] as? Int) ?? 0,
                cacheRead: (usageD["cache_read_input_tokens"] as? Int) ?? 0,
                output: (usageD["output_tokens"] as? Int) ?? 0)
            return UsageRecord(
                messageId: r["messageId"] as? String,
                requestId: r["requestId"] as? String,
                model: (r["model"] as? String) ?? "<unknown>",
                usage: usage,
                timestamp: parseDate(r["timestamp"] as? String),
                isSidechain: (r["isSidechain"] as? Bool) ?? false)
        }

        let agg = aggregate(records, options: AggregateOptions(now: now, cap: cap), costModel: Pricing())
        let e = (root["expect"] as? [String: Any]) ?? [:]

        // Whole-token scalars (assert only the ones this fixture pins; these are never
        // JSON null, so `as? Int == nil` means "absent -> skip").
        if let v = e["total"] as? Int { XCTAssertEqual(agg.total, v, "total \(ctx)") }
        if let v = e["today"] as? Int { XCTAssertEqual(agg.today, v, "today \(ctx)") }
        if let v = e["thisWeek"] as? Int { XCTAssertEqual(agg.thisWeek, v, "thisWeek \(ctx)") }
        if let v = e["rolling5h"] as? Int { XCTAssertEqual(agg.rolling5h, v, "rolling5h \(ctx)") }

        if let bc = e["byClass"] as? [String: Any] {
            if let v = bc["input"] as? Int { XCTAssertEqual(agg.byClass.input, v, "byClass.input \(ctx)") }
            if let v = bc["cacheCreate"] as? Int { XCTAssertEqual(agg.byClass.cacheCreate, v, "byClass.cacheCreate \(ctx)") }
            if let v = bc["cacheRead"] as? Int { XCTAssertEqual(agg.byClass.cacheRead, v, "byClass.cacheRead \(ctx)") }
            if let v = bc["output"] as? Int { XCTAssertEqual(agg.byClass.output, v, "byClass.output \(ctx)") }
        }

        if let bs = e["bySurface"] as? [String: Any] {
            for (k, raw) in bs {
                guard let v = raw as? Int, let surface = Surface(rawValue: k) else {
                    XCTFail("bad bySurface entry \(k) \(ctx)"); continue
                }
                // A surface key only exists once it has tokens, so missing == 0.
                XCTAssertEqual(agg.bySurface[surface] ?? 0, v, "bySurface.\(k) \(ctx)")
            }
        }

        // Tokens-per-model: exact map (same keys, same integer counts).
        if let bm = e["byModel"] as? [String: Any] {
            var expected: [String: Int] = [:]
            for (k, raw) in bm { if let v = raw as? Int { expected[k] = v } }
            XCTAssertEqual(agg.byModel, expected, "byModel \(ctx)")
        }

        if let w = e["window"] as? [String: Any] {
            if let v = w["active"] as? Bool { XCTAssertEqual(agg.window.active, v, "window.active \(ctx)") }
            if let v = w["tokens"] as? Int { XCTAssertEqual(agg.window.tokens, v, "window.tokens \(ctx)") }
            if let v = w["calibratedCap"] as? Int { XCTAssertEqual(agg.window.calibratedCap, v, "window.calibratedCap \(ctx)") }
            // resetMs: JSON null -> expect idle (resetAt nil); a number -> epoch ms.
            if w.keys.contains("resetMs") {
                let expectedMs: Int? = (w["resetMs"] is NSNull) ? nil : (w["resetMs"] as? Int)
                let actualMs: Int? = agg.window.resetAt.map { Int(($0.timeIntervalSince1970 * 1000).rounded()) }
                XCTAssertEqual(actualMs, expectedMs, "window.resetMs \(ctx)")
            }
            // pct: JSON null -> expect tokenPct nil (no configured cap basis).
            if w.keys.contains("pct") {
                let expectedPct: Int? = (w["pct"] is NSNull) ? nil : (w["pct"] as? Int)
                XCTAssertEqual(agg.window.tokenPct, expectedPct, "window.pct \(ctx)")
            }
        }

        if let cost = e["cost"] as? [String: Any] {
            XCTAssertNotNil(agg.cost, "cost block expected (Pricing was injected) \(ctx)")
            if let aggCost = agg.cost {
                if let v = cost["total"] as? Double { XCTAssertEqual(aggCost.total, v, accuracy: 1e-9, "cost.total \(ctx)") }
                if let v = cost["today"] as? Double { XCTAssertEqual(aggCost.today, v, accuracy: 1e-9, "cost.today \(ctx)") }
                if let v = cost["unpricedTokens"] as? Int { XCTAssertEqual(aggCost.unpricedTokens, v, "cost.unpricedTokens \(ctx)") }
                if let bm = cost["byModel"] as? [String: Any] {
                    var expected: [String: Double] = [:]
                    for (k, raw) in bm { if let v = raw as? Double { expected[k] = v } }
                    XCTAssertEqual(Set(aggCost.byModel.keys), Set(expected.keys), "cost.byModel keys \(ctx)")
                    for (k, v) in expected {
                        XCTAssertEqual(aggCost.byModel[k] ?? .nan, v, accuracy: 1e-9, "cost.byModel[\(k)] \(ctx)")
                    }
                }
            }
        }
    }
}
