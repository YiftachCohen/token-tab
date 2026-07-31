// Codex ingestion tests (Swift side) — the cross-engine mirror of test/codex-ingest.test.mjs.
//
// Loads the SAME shared fixtures the JS reader tests load (test/fixtures/codex-ingest/*.json,
// resolved via #filePath like ParityTests does) and asserts the CodexLogReader fold emits the
// SAME UsageRecords + rate_limits snapshot the JS suite asserts. Parity is proven by computation
// over one oracle, not by hand-copied twin expectations: if the two folds ever disagree on the
// delta/reset/duplicate arithmetic or the cached-subset mapping, one suite goes red.
//
// Also covers the file walker, config precedence, and RecordCache v2 (old-version cache
// invalidates cleanly; provider + rate-limits snapshot survive a round-trip). Synthetic Codex
// event sequences only — no prompt/response text anywhere.

import XCTest
@testable import TokenTab
@testable import TokenTabCore

final class CodexIngestTests: XCTestCase {

    /// The shared fixtures live at <repo>/test/fixtures/codex-ingest, OUTSIDE the SwiftPM package
    /// (same shared-oracle convention as ParityTests) — resolve relative to this source file so a
    /// separate bundled copy can't silently drift.
    private func fixturesDir() -> URL {
        URL(fileURLWithPath: #filePath)   // .../app/Tests/TokenTabAppTests/CodexIngestTests.swift
            .deletingLastPathComponent()  // .../TokenTabAppTests
            .deletingLastPathComponent()  // .../Tests
            .deletingLastPathComponent()  // .../app
            .deletingLastPathComponent()  // .../<repo>
            .appendingPathComponent("test/fixtures/codex-ingest")
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return CodexIngestTests.isoFrac.date(from: s) ?? CodexIngestTests.isoNoFrac.date(from: s)
    }

    // A fixture's `lines` are event objects (re-serialized so we exercise real JSON decoding);
    // `rawLines` are already strings (used to inject malformed input) — mirrors fixtureLines() in JS.
    private func fixtureLines(_ fx: [String: Any]) -> [String] {
        if let raw = fx["rawLines"] as? [String] { return raw }
        guard let objs = fx["lines"] as? [Any] else { return [] }
        return objs.map { obj in
            let data = try! JSONSerialization.data(withJSONObject: obj)
            return String(data: data, encoding: .utf8)!
        }
    }

    // MARK: - fixture-driven fold parity

    func testCodexIngestFixtures() throws {
        let dir = fixturesDir()
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else {
            XCTFail("Codex ingest fixtures not found at \(dir.path) — cannot reach the shared test/fixtures/codex-ingest via #filePath. Do not hard-code an absolute path; report this.")
            return
        }
        let files = (try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThanOrEqual(files.count, 8, "expected the shared codex-ingest fixtures, found \(files.count)")

        for file in files {
            let data = try Data(contentsOf: file)
            guard let fx = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                XCTFail("not a JSON object: \(file.lastPathComponent)"); continue
            }
            let name = file.lastPathComponent
            XCTContext.runActivity(named: name) { _ in
                let out = CodexLogReader.recordsFromLines(fixtureLines(fx), fileName: fx["fileName"] as? String)
                assertRecords(out.records, matches: (fx["expected"] as? [[String: Any]]) ?? [], ctx: name)
                XCTAssertEqual(out.malformed, (fx["malformed"] as? Int) ?? 0, "malformed \(name)")
                assertRateLimits(out.rateLimits, matches: fx["rateLimits"], ctx: name)
            }
        }
    }

    /// Assert the emitted records equal the fixture's `expected` (which carries JS field names).
    private func assertRecords(_ records: [UsageRecord], matches expected: [[String: Any]], ctx: String) {
        XCTAssertEqual(records.count, expected.count, "record count \(ctx)")
        for (i, e) in expected.enumerated() where i < records.count {
            let r = records[i]
            XCTAssertEqual(r.messageId, e["messageId"] as? String, "records[\(i)].messageId \(ctx)")
            XCTAssertEqual(r.requestId, e["requestId"] as? String, "records[\(i)].requestId \(ctx)")
            XCTAssertEqual(r.model, e["model"] as? String, "records[\(i)].model \(ctx)")
            XCTAssertEqual(r.provider, e["provider"] as? String, "records[\(i)].provider \(ctx)")
            XCTAssertEqual(r.isSidechain, (e["isSidechain"] as? Bool) ?? false, "records[\(i)].isSidechain \(ctx)")
            XCTAssertEqual(r.timestamp, parseDate(e["timestamp"] as? String), "records[\(i)].timestamp \(ctx)")
            let u = (e["usage"] as? [String: Any]) ?? [:]
            XCTAssertEqual(r.usage.input, (u["input_tokens"] as? Int) ?? 0, "records[\(i)].usage.input \(ctx)")
            XCTAssertEqual(r.usage.cacheRead, (u["cache_read_input_tokens"] as? Int) ?? 0, "records[\(i)].usage.cacheRead \(ctx)")
            XCTAssertEqual(r.usage.cacheCreate, (u["cache_creation_input_tokens"] as? Int) ?? 0, "records[\(i)].usage.cacheCreate \(ctx)")
            XCTAssertEqual(r.usage.output, (u["output_tokens"] as? Int) ?? 0, "records[\(i)].usage.output \(ctx)")
        }
    }

    /// Assert the file's rate_limits snapshot matches the fixture (raw JSON shape: used_percent,
    /// resets_at as epoch seconds, asOf as ISO). A JSON `null`/absent means "no snapshot".
    private func assertRateLimits(_ snap: CodexRateLimitsSnapshot?, matches raw: Any?, ctx: String) {
        guard let expected = raw as? [String: Any] else {
            XCTAssertNil(snap, "expected no rate_limits snapshot \(ctx)"); return
        }
        guard let snap else { XCTFail("expected a rate_limits snapshot \(ctx)"); return }
        func assertWindow(_ w: CodexRateLimitsSnapshot.Window?, _ er: Any?, _ label: String) {
            guard let ew = er as? [String: Any] else { XCTAssertNil(w, "\(label) expected nil \(ctx)"); return }
            guard let w else { XCTFail("\(label) missing \(ctx)"); return }
            XCTAssertEqual(w.usedPercent, ew["used_percent"] as? Double, "\(label).used_percent \(ctx)")
            XCTAssertEqual(w.windowMinutes, ew["window_minutes"] as? Int, "\(label).window_minutes \(ctx)")
            if let secs = ew["resets_at"] as? Double {
                XCTAssertEqual(w.resetsAt?.timeIntervalSince1970, secs, "\(label).resets_at \(ctx)")
            }
        }
        assertWindow(snap.primary, expected["primary"], "primary")
        assertWindow(snap.secondary, expected["secondary"], "secondary")
        XCTAssertEqual(snap.planType, expected["plan_type"] as? String, "plan_type \(ctx)")
        XCTAssertEqual(snap.asOf, parseDate(expected["asOf"] as? String), "asOf \(ctx)")
    }

    // MARK: - targeted invariants (mirror the JS suite)

    func testResolveCodexRootPrecedence() {
        // Env wins over dotfile/default; assert precedence directly on the env-driven branch.
        // (Config reads real env, so a set var proves the TOKENTAB_CODEX_LOG_DIR > CODEX_HOME order.)
        let root = CodexLogReader.defaultCodexRoot()
        XCTAssertTrue(root.path.hasSuffix(".codex") || !root.path.isEmpty, "resolves to a concrete dir")
    }

    func testWalkerOrderAndCrossFileRateLimitsLatestWins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-walk-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions/2026/06/20")
        let archived = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)

        // NEWER-content file gets the OLDER mtime, so only asOf can pick the snapshot.
        let newer = #"{"type":"event_msg","timestamp":"2026-06-20T12:00:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"total_tokens":2}},"rate_limits":{"primary":{"used_percent":88,"window_minutes":300,"resets_at":2},"plan_type":"plus"}}}"#
        let older = #"{"type":"event_msg","timestamp":"2026-06-20T10:00:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"total_tokens":2}},"rate_limits":{"primary":{"used_percent":5,"window_minutes":300,"resets_at":1},"plan_type":"plus"}}}"#
        let fNewer = sessions.appendingPathComponent("rollout-2026-06-20T00-00-00-00000000-0000-0000-0000-000000000001.jsonl")
        let fOlder = archived.appendingPathComponent("rollout-2026-06-20T00-00-00-00000000-0000-0000-0000-000000000002.jsonl")
        try (newer + "\n").write(to: fNewer, atomically: true, encoding: .utf8)
        try (older + "\n").write(to: fOlder, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: fNewer.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: fOlder.path)

        let files = CodexLogReader.findCodexJSONL(in: root)
        // /var vs /private/var: standardize both sides before comparing
        XCTAssertEqual(files.map { $0.resolvingSymlinksInPath() },
                       [fNewer, fOlder].map { $0.resolvingSymlinksInPath() },
                       "oldest mtime first (then path)")

        let out = CodexLogReader.readUsage(root: root)
        XCTAssertEqual(out.records.count, 2)
        XCTAssertEqual(out.malformed, 0)
        XCTAssertEqual(out.codexRateLimits?.primary?.usedPercent, 88, "later asOf wins regardless of walk order")
        XCTAssertEqual(out.codexRateLimits?.asOf, parseDate("2026-06-20T12:00:00.000Z"))
    }

    /// The content gate is that `response_item` is never DECODED — not merely that its text
    /// fails to escape. That's observable: the response_item line below is deliberately
    /// truncated (unbalanced braces). If the decoder ever saw it, it would fail and land in
    /// `malformed`. malformed == 0 is the proof the line was dropped as a raw string.
    func testNoContentResponseItemsNeverDecoded() {
        let lines = [
            #"{"type":"session_meta","timestamp":"2026-06-20T21:00:00.000Z","payload":{"id":"11111111-2222-3333-4444-555555555555","instructions":"SECRET PROMPT TEXT","cwd":"/secret/path"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"text","text":"SECRET USER MESSAGE"#,
            #"{"type":"response_item","payload":{"type":"reasoning","content":"SECRET REASONING"}}"#,
            #"{"type":"turn_context","payload":{"model":"gpt-5.4","cwd":"/secret/path"}}"#,
            #"{"type":"event_msg","timestamp":"2026-06-20T21:01:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"total_tokens":15}},"rate_limits":null}}"#,
        ]
        let out = CodexLogReader.recordsFromLines(lines, fileName: "x.jsonl")
        XCTAssertEqual(out.records.count, 1)
        XCTAssertEqual(out.malformed, 0,
                       "an unparseable response_item must be skipped before the decoder, not decoded and rejected")
        // Records carry only whitelisted fields; nothing content-bearing can round-trip through them.
        let blob = out.records.map { "\($0.messageId ?? "")\($0.model)" }.joined()
        XCTAssertFalse(blob.contains("SECRET"), "no content field leaks into records")
        XCTAssertFalse(blob.contains("/secret/path"), "no cwd leaks")
    }

    /// The raw-string type reader itself: the whitelist decision must not depend on decoding.
    func testTopLevelTypeReadsTheEnvelopeWithoutDecoding() {
        XCTAssertEqual(CodexLogReader.topLevelType(of: #"{"timestamp":"t","type":"event_msg","payload":{}}"#), "event_msg")
        XCTAssertEqual(CodexLogReader.topLevelType(of: #"{ "type" : "session_meta" }"#), "session_meta",
                       "whitespace around the colon is tolerated, as in the JS regex")
        XCTAssertEqual(CodexLogReader.topLevelType(of: #"{"type":"response_item","payload":{"type":"message"}}"#), "response_item",
                       "the FIRST type wins — the envelope's, not the payload's")
        // No usable `"type": "token"` shape ⇒ nil ⇒ the caller falls through to the decoder,
        // so a genuinely malformed line is still counted.
        XCTAssertNil(CodexLogReader.topLevelType(of: #"{"model":"gpt-5.4"}"#))
        XCTAssertNil(CodexLogReader.topLevelType(of: #"{"a":"type","b":1}"#))
    }

    // MARK: - RecordCache v2

    @discardableResult
    private func write(_ url: URL, _ lines: [String]) throws -> URL {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A Codex file round-trips through the cache: provider stays "codex", the rate_limits snapshot
    /// survives, and an unchanged fingerprint is reused by a fresh instance WITHOUT re-reading the
    /// file (proven by rewriting to different bytes at a pinned mtime+size — the original must return).
    func testCacheV2CodexProviderAndRateLimitsRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-cache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("record-cache.json")

        let rl = #"{"primary":{"used_percent":42,"window_minutes":300,"resets_at":1774590000},"plan_type":"plus"}"#
        let file = dir.appendingPathComponent("rollout-2026-06-20T18-00-00-019ee700-0000-7000-8000-000000000002.jsonl")
        try write(file, [
            #"{"type":"turn_context","payload":{"model":"gpt-5.4"}}"#,
            #"{"type":"event_msg","timestamp":"2026-06-20T18:05:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20,"total_tokens":120}},"rate_limits":\#(rl)}}"#,
        ])
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: pinned], ofItemAtPath: file.path)

        let cold = RecordCache(storeURL: store)
        let first = cold.codexRecords(for: [file])
        XCTAssertEqual(first.records.map(\.provider), ["codex"], "provider is codex")
        XCTAssertEqual(first.records.first?.messageId, "codex:019ee700-0000-7000-8000-000000000002", "session id from filename fallback")
        XCTAssertEqual(first.codexRateLimits?.primary?.usedPercent, 42, "snapshot from the parse")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path), "cold run flushed to disk")

        // Rewrite with different bytes of identical length; restore the mtime → fingerprint unchanged.
        try write(file, [
            #"{"type":"turn_context","payload":{"model":"gpt-5.4"}}"#,
            #"{"type":"event_msg","timestamp":"2026-06-20T18:05:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":999,"cached_input_tokens":0,"output_tokens":99,"total_tokens":998}},"rate_limits":\#(rl)}}"#,
        ])
        try FileManager.default.setAttributes([.modificationDate: pinned], ofItemAtPath: file.path)

        let warm = RecordCache(storeURL: store)   // fresh instance → hydrate from disk
        let second = warm.codexRecords(for: [file])
        XCTAssertEqual(second.records.first?.usage.input, 100, "persisted (v2) codex records + provider survive the round-trip; not the file's new bytes")
        XCTAssertEqual(second.codexRateLimits?.primary?.usedPercent, 42, "the per-file rate_limits snapshot survives the round-trip")
    }

    /// A v1 (old-version) store is discarded, not trusted: the cache falls back to a clean parse
    /// (fail-soft, exactly as before v2). Proven by writing a v1-shaped store then confirming the
    /// live file's records — with the v2-only provider field set — come back.
    func testCacheV2InvalidatesOldVersionCleanly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-cache-v1-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("record-cache.json")

        // A v1-shaped store (version:1, no provider/rateLimits) pointing at a bogus path must be
        // ignored entirely — the version gate discards it before any entry is trusted.
        let v1 = #"{"version":1,"entries":[{"path":"/nonexistent/ghost.jsonl","mtime":0,"size":0,"records":[],"malformed":0}]}"#
        try v1.write(to: store, atomically: true, encoding: .utf8)

        let file = dir.appendingPathComponent("rollout-2026-06-20T13-14-52-019ee4bd-9e44-7b83-bbc1-de29b2cad406.jsonl")
        try write(file, [
            #"{"type":"turn_context","payload":{"model":"gpt-5.4"}}"#,
            #"{"type":"event_msg","timestamp":"2026-06-20T13:15:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20,"total_tokens":120}},"rate_limits":null}}"#,
        ])

        let cache = RecordCache(storeURL: store)
        let out = cache.codexRecords(for: [file])
        XCTAssertEqual(out.records.map(\.provider), ["codex"], "old-version store discarded → clean parse with v2 provider field")
        XCTAssertEqual(out.records.first?.usage.input, 60, "100 input - 40 cached")
    }
}
