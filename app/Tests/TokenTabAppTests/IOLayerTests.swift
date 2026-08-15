// Characterization tests for the I/O shell (LogReader + RecordCache) — the file-walking,
// JSONL-decoding, and per-file mtime+size caching layer that feeds the pure engine.
//
// These pin the behavior the source comments promise: only assistant-with-usage lines
// become records, malformed lines are tolerated (counted, never fatal), timestamps parse
// with and without fractional seconds, and the cache re-parses ONLY changed files while
// keeping byte-identical record order against the uncached path. Synthetic ids/tokens
// only. Fixtures deliberately embed a `"content"` string to prove the decoder cannot
// surface it (the `Line` Codable has no such field) — this lives under app/Tests, so it
// does not trip the CI content-audit grep that scans app/Sources.

import XCTest
@testable import TokenTab
@testable import TokenTabCore

final class IOLayerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokentab-io-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Write `lines` (no trailing newlines needed) as a JSONL file and return its URL.
    @discardableResult
    private func write(_ name: String, _ lines: [String]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A FRESH URL for a file in `dir`. `URL.resourceValues` caches stat results per URL
    /// instance, so a test that re-stats the same instance after modifying the file reads
    /// stale values — production always mints fresh URLs via findJSONL, and so must tests.
    private func fresh(_ name: String) -> URL { dir.appendingPathComponent(name) }

    /// A valid JSONL assistant line carrying synthetic usage — the per-file unit the cache
    /// tests append/rewrite.
    private func assistantLine(id: String, req: String,
                               model: String = "claude-opus-4-8",
                               ts: String = "2026-06-20T10:00:00Z",
                               usage: (Int, Int, Int, Int) = (10, 0, 0, 5)) -> String {
        let (i, cc, cr, o) = usage
        return #"{"type":"assistant","requestId":"\#(req)","timestamp":"\#(ts)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(i),"cache_creation_input_tokens":\#(cc),"cache_read_input_tokens":\#(cr),"output_tokens":\#(o)}}}"#
    }

    // MARK: - LogReader.parseFile

    /// Only assistant-with-usage lines become records; a `user` line and a malformed line are
    /// not. The bad line is counted, never fatal. Timestamps parse with and without fractional
    /// seconds. The assistant line also carries `"content":"SECRET"`: it is structurally
    /// impossible for it to reach a UsageRecord (the type has no content field), so the parse
    /// simply ignores it — documenting the trust guarantee at the I/O boundary.
    func testParseFileSkipsNonAssistantAndToleratesMalformed() throws {
        let url = try write("a.jsonl", [
            #"{"type":"user","message":{"content":"SECRET"}}"#,
            #"{"type":"assistant","requestId":"r1","timestamp":"2026-06-20T10:00:01.234Z","message":{"id":"m1","model":"claude-opus-4-8","content":"SECRET","usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":2}}}"#,
            "{ not valid json",
            #"{"type":"assistant","requestId":"r2","timestamp":"2026-06-20T10:00:02Z","message":{"id":"m2","model":"us.anthropic.claude-3-5-sonnet-20241022-v2:0","usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}"#,
        ])
        let (records, malformed) = LogReader.parseFile(url)
        XCTAssertEqual(records.count, 2, "only assistant-with-usage lines become records")
        XCTAssertEqual(malformed, 1, "the one bad line is counted, not fatal")
        XCTAssertNotNil(records[0].timestamp, "fractional-seconds timestamp parses")
        XCTAssertNotNil(records[1].timestamp, "non-fractional timestamp parses")
        XCTAssertEqual(records[0].usage.sum, 62, "10+20+30+2")
        XCTAssertEqual(records[0].requestId, "r1")
        XCTAssertEqual(records[1].requestId, "r2")
    }

    /// An assistant line with no `usage` object is not a usage record (it is skipped, not
    /// malformed). A blank line is also ignored without inflating the malformed count.
    func testParseFileSkipsAssistantWithoutUsageAndBlankLines() throws {
        let url = try write("b.jsonl", [
            #"{"type":"assistant","requestId":"r1","message":{"id":"m1","model":"claude-opus-4-8"}}"#,
            "",
            "   ",
            assistantLine(id: "m2", req: "r2"),
        ])
        let (records, malformed) = LogReader.parseFile(url)
        XCTAssertEqual(records.count, 1, "the usage-less assistant line is skipped, the real one counts")
        XCTAssertEqual(malformed, 0, "blank/whitespace lines are ignored, not malformed")
        XCTAssertEqual(records[0].messageId, "m2")
    }

    /// A vanished/unreadable file is empty, not a crash (tolerated mid-walk).
    func testParseFileMissingFileIsEmpty() {
        let missing = dir.appendingPathComponent("does-not-exist.jsonl")
        let (records, malformed) = LogReader.parseFile(missing)
        XCTAssertEqual(records.count, 0)
        XCTAssertEqual(malformed, 0)
    }

    // MARK: - LogReader.findJSONL

    /// Parity with the JS walker: a *.jsonl under a HIDDEN directory is found (the JS findJsonl
    /// recurses into all directories), while the hidden live-cache file (.token-tab-live.json,
    /// not *.jsonl) is still excluded. Pins that findJSONL does not skip hidden paths.
    func testFindJSONLDoesNotSkipHiddenPaths() throws {
        // a normal log
        try write("visible.jsonl", [assistantLine(id: "m1", req: "r1")])
        // a log under a hidden subdir — JS would find this; Swift must too
        let hiddenDir = dir.appendingPathComponent(".hidden")
        try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)
        try (assistantLine(id: "m2", req: "r2") + "\n")
            .write(to: hiddenDir.appendingPathComponent("buried.jsonl"), atomically: true, encoding: .utf8)
        // the hidden live-cache file must stay excluded (not *.jsonl)
        try "{}".write(to: dir.appendingPathComponent(".token-tab-live.json"), atomically: true, encoding: .utf8)

        let found = LogReader.findJSONL(in: dir).map { $0.lastPathComponent }
        XCTAssertTrue(found.contains("visible.jsonl"))
        XCTAssertTrue(found.contains("buried.jsonl"), "a *.jsonl under a hidden dir must be found (JS parity)")
        XCTAssertFalse(found.contains(".token-tab-live.json"), "the live-cache file is not *.jsonl → excluded")
    }

    // MARK: - RecordCache

    /// Caching never changes the result: a fresh cache returns the same records (same count,
    /// same order) and the same malformed count as the one-shot uncached path. A malformed
    /// line is included so the malformed-count parity is pinned too.
    func testRecordCacheEquivalentToUncachedPath() throws {
        try write("a.jsonl", [
            assistantLine(id: "m1", req: "r1"),
            "{ not valid json",
            assistantLine(id: "m2", req: "r2"),
        ])
        try write("b.jsonl", [assistantLine(id: "m3", req: "r3")])

        let files = LogReader.findJSONL(in: dir)
        let cached = RecordCache().records(for: files)
        let uncached = LogReader.readRecords(from: files)

        XCTAssertEqual(cached.records.count, uncached.records.count)
        XCTAssertEqual(cached.malformed, uncached.malformed)
        XCTAssertEqual(cached.malformed, 1)
        XCTAssertEqual(cached.records.map(\.messageId), uncached.records.map(\.messageId),
                       "cache returns records in the same (files) order as the uncached path")
    }

    /// An unchanged file is reused; a file whose size changes (an appended line) is re-parsed.
    /// Asserted via the observable record-count delta, never by reaching into cache internals.
    func testRecordCacheReparsesChangedFilesOnly() throws {
        try write("a.jsonl", [assistantLine(id: "m1", req: "r1")])
        try write("b.jsonl", [assistantLine(id: "m2", req: "r2")])
        let cache = RecordCache()

        let first = cache.records(for: LogReader.findJSONL(in: dir))
        XCTAssertEqual(first.records.count, 2)

        // Append a new record to a.jsonl (changes size → cache invalidates that file only).
        let a = dir.appendingPathComponent("a.jsonl")
        let handle = try FileHandle(forWritingTo: a)
        handle.seekToEndOfFile()
        handle.write((assistantLine(id: "m3", req: "r3") + "\n").data(using: .utf8)!)
        try handle.close()

        let second = cache.records(for: LogReader.findJSONL(in: dir))
        XCTAssertEqual(second.records.count, 3, "the changed file is re-parsed, the other reused")

        let third = cache.records(for: LogReader.findJSONL(in: dir))
        XCTAssertEqual(third.records.count, 3, "no change → stable")
    }

    /// After a populated cache, a deleted file's records disappear on the next refresh and
    /// nothing crashes (the cache drops vanished entries so it stays bounded).
    func testRecordCacheDropsVanishedFiles() throws {
        try write("a.jsonl", [assistantLine(id: "m1", req: "r1")])
        try write("b.jsonl", [assistantLine(id: "m2", req: "r2")])
        let cache = RecordCache()

        let first = cache.records(for: LogReader.findJSONL(in: dir))
        XCTAssertEqual(first.records.count, 2)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("b.jsonl"))

        let second = cache.records(for: LogReader.findJSONL(in: dir))
        XCTAssertEqual(second.records.count, 1, "the deleted file's records are gone")
        XCTAssertEqual(second.records.first?.messageId, "m1")
    }

    // MARK: - RecordCache persistence (cross-launch)

    /// The cache PERSISTS across instances (a fresh app launch): a second `RecordCache` pointed
    /// at the same store file hydrates the parsed records from disk and reuses them for a file
    /// whose fingerprint (mtime+size) is unchanged — WITHOUT re-reading it. This is what turns
    /// the slow cold start (a full re-parse of the whole log history every launch) into a near-
    /// instant incremental one. Proven by rewriting the file to a DIFFERENT record while pinning
    /// its mtime+size: the original record must come back (a re-parse would yield the new one).
    /// The other cache tests use `storeURL: nil` (the default) and stay hermetic; only these opt in.
    func testPersistentCacheReusesAcrossInstancesByFingerprint() throws {
        let store = dir.appendingPathComponent("record-cache.json")
        let url = try write("s.jsonl", [assistantLine(id: "m1", req: "r1")])
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: pinned], ofItemAtPath: url.path)

        let cold = RecordCache(storeURL: store)
        XCTAssertEqual(cold.records(for: LogReader.findJSONL(in: dir)).records.map(\.messageId), ["m1"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path), "the cold run flushed the cache to disk")

        // Rewrite with a DIFFERENT record of identical byte length (same-length ids) and restore
        // the mtime, so the fingerprint is byte-identical to what the cold run persisted.
        try (assistantLine(id: "m2", req: "r2") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: pinned], ofItemAtPath: url.path)

        let warm = RecordCache(storeURL: store)   // fresh instance → must hydrate from the store file
        XCTAssertEqual(warm.records(for: LogReader.findJSONL(in: dir)).records.map(\.messageId), ["m1"],
                       "a new instance reused the persisted record for an unchanged fingerprint, not the file's new bytes")
    }

    /// Safety counterpart: a real change (different size) busts the persisted fingerprint, so a
    /// fresh instance re-parses rather than serving stale records.
    func testPersistentCacheReparsesWhenFingerprintChanges() throws {
        let store = dir.appendingPathComponent("record-cache.json")
        try write("s.jsonl", [assistantLine(id: "m1", req: "r1")])
        _ = RecordCache(storeURL: store).records(for: LogReader.findJSONL(in: dir))   // persist m1

        try write("s.jsonl", [assistantLine(id: "m1", req: "r1"), assistantLine(id: "m2", req: "r2")])

        let warm = RecordCache(storeURL: store)
        XCTAssertEqual(warm.records(for: LogReader.findJSONL(in: dir)).records.map(\.messageId), ["m1", "m2"],
                       "a changed fingerprint forces a re-parse, never a stale reuse")
    }

    /// A corrupt or wrong-version store file is ignored, not trusted: the cache falls back to a
    /// clean parse (fail-soft, exactly as before persistence existed) and never throws.
    func testPersistentCacheToleratesCorruptStore() throws {
        let store = dir.appendingPathComponent("record-cache.json")
        try "{ not the cache schema".write(to: store, atomically: true, encoding: .utf8)
        try write("s.jsonl", [assistantLine(id: "m1", req: "r1")])

        let cache = RecordCache(storeURL: store)
        XCTAssertEqual(cache.records(for: LogReader.findJSONL(in: dir)).records.map(\.messageId), ["m1"],
                       "a corrupt store is discarded and the logs are parsed fresh")
    }

    // MARK: - Line breaking and byte-level tolerance

    /// A raw U+2028 / U+2029 / U+0085 inside a log line is line CONTENT, not a line break.
    ///
    /// `JSON.stringify` emits all three unescaped, so any assistant turn quoting a file that
    /// contains one (minified JS, exported JSON) writes exactly this shape: one physical line.
    /// Foundation's `enumerateLines` breaks on all three, so the reader used to cut this record
    /// into truncated fragments, fail to decode every one, and drop the tokens entirely — while
    /// the CLI, which splits the way Node's readline does, counted them. Same Mac, two answers.
    /// Twin of test/io.test.mjs "a record containing U+2028/U+2029/U+0085 stays ONE record".
    func testParseFileTreatsUnicodeSeparatorsAsLineContent() throws {
        let ls = "\u{2028}", ps = "\u{2029}", nel = "\u{0085}"
        let text = "before\(ls)after\(nel)tail\(ps)end"
        let line = #"{"type":"assistant","requestId":"rsep","timestamp":"2026-06-20T10:00:01Z","message":{"id":"msep","model":"claude-sonnet-4-5","content":"\#(text)","usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":5000,"output_tokens":200}}}"#
        // Written as ONE line — the separators are inside the JSON string, not between records.
        let url = dir.appendingPathComponent("sep.jsonl")
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)

        let (records, malformed) = LogReader.parseFile(url)
        XCTAssertEqual(records.count, 1, "one physical line is one record, not several fragments")
        XCTAssertEqual(malformed, 0, "no fragment may be reported as malformed")
        XCTAssertEqual(records.first?.usage.sum, 6200, "1000 + 5000 + 200 — the whole record counts")
    }

    /// The same rule for the dotfile parser, which used `\.isNewline` (the same over-broad
    /// Unicode set): a value containing one of those scalars must not be cut in half.
    func testEnvFileSplitsOnASCIINewlinesOnly() {
        let parsed = EnvFile.parse("TOKENTAB_MODE=bed\u{2028}rock\nTOKENTAB_WINDOW_CAP=400000\r\n")
        XCTAssertEqual(parsed["TOKENTAB_MODE"], "bed\u{2028}rock", "a U+2028 is value content, not a line break")
        XCTAssertEqual(parsed["TOKENTAB_WINDOW_CAP"], "400000", "CRLF still yields a clean value")
    }

    /// A stray non-UTF-8 byte — e.g. a half-written multi-byte character at the tail of a log
    /// being appended to right now — must cost at most its own line. A strict `String(data:
    /// encoding:)` returned nil for the whole file, so the reader silently discarded every good
    /// record in it AND counted nothing malformed: whole-history loss with no signal.
    /// Twin of test/io.test.mjs "an invalid UTF-8 byte does not discard the rest of the file".
    func testParseFileSurvivesInvalidUTF8() throws {
        let url = dir.appendingPathComponent("bad.jsonl")
        var data = Data()
        data.append(Data((assistantLine(id: "mg", req: "rg", usage: (1000, 0, 500, 0)) + "\n").utf8))
        data.append(contentsOf: [0xFF, 0xFE, 0x0A])   // invalid UTF-8, own line
        try data.write(to: url)

        let (records, _) = LogReader.parseFile(url)
        XCTAssertEqual(records.count, 1, "the good record survives a damaged neighbour")
        XCTAssertEqual(records.first?.usage.sum, 1500)
    }

    // MARK: - Incremental tail parsing (append-only files re-parse only their appended bytes)

    /// The tail-only invariant, proven the strong way: after caching, the file's FIRST line is
    /// overwritten in place with same-length garbage and a new record appended. The cache must
    /// serve the original prefix record untouched — a full re-parse would see the garbage
    /// (one malformed, no m1) — while parsing the appended record.
    func testRecordCacheParsesOnlyTheAppendedTail() throws {
        let line1 = assistantLine(id: "m1", req: "r1")
        let url = try write("a.jsonl", [line1])
        let cache = RecordCache()
        XCTAssertEqual(cache.records(for: [fresh("a.jsonl")]).records.map(\.messageId), ["m1"])

        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 0)
        handle.write(Data(String(repeating: "X", count: line1.utf8.count).utf8))
        handle.seekToEndOfFile()
        handle.write(Data((assistantLine(id: "m2", req: "r2") + "\n").utf8))
        try handle.close()

        let out = cache.records(for: [fresh("a.jsonl")])
        XCTAssertEqual(out.records.map(\.messageId), ["m1", "m2"],
                       "the prefix came from the cache (tail-only read), the appended record was parsed")
        XCTAssertEqual(out.malformed, 0, "the overwritten prefix was never re-read")
    }

    /// A trailing line with no newline yet (a record mid-write) is counted transiently —
    /// matching the one-shot parse — but NEVER cached, so when its terminator arrives the
    /// completed line parses whole. Caching the half would poison the resume offset: its
    /// remainder would arrive as a garbage "line" while the half stayed malformed forever.
    func testRecordCachePartialLineCompletesAcrossRefreshes() throws {
        let full = assistantLine(id: "m2", req: "r2")
        let firstHalf = String(full.prefix(full.count / 2))
        let url = dir.appendingPathComponent("p.jsonl")
        try (assistantLine(id: "m1", req: "r1") + "\n" + firstHalf)
            .write(to: url, atomically: true, encoding: .utf8)

        let cache = RecordCache()
        let first = cache.records(for: [fresh("p.jsonl")])
        XCTAssertEqual(first.records.map(\.messageId), ["m1"], "the half line is not a record yet")
        XCTAssertEqual(first.malformed, 1, "…but it counts as malformed, matching the one-shot parse")

        let again = cache.records(for: [fresh("p.jsonl")])
        XCTAssertEqual(again.records.map(\.messageId), ["m1"])
        XCTAssertEqual(again.malformed, 1, "transient count is stable across refreshes, never accumulating")

        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data((String(full.dropFirst(firstHalf.count)) + "\n").utf8))
        try handle.close()

        let done = cache.records(for: [fresh("p.jsonl")])
        XCTAssertEqual(done.records.map(\.messageId), ["m1", "m2"], "the completed line parses whole")
        XCTAssertEqual(done.malformed, 0)
    }

    /// Shrinkage means the file was rewritten, not appended — the cached prefix is void and
    /// the whole file re-parses (the append-only fast path must never merge across it).
    func testRecordCacheShrunkFileReparsesFully() throws {
        let url = try write("s.jsonl", [assistantLine(id: "m1", req: "r1"),
                                        assistantLine(id: "m2", req: "r2")])
        let cache = RecordCache()
        XCTAssertEqual(cache.records(for: [fresh("s.jsonl")]).records.count, 2)

        try write("s.jsonl", [assistantLine(id: "m3", req: "r3")])
        XCTAssertEqual(cache.records(for: [fresh("s.jsonl")]).records.map(\.messageId), ["m3"],
                       "a shrunk file is fully re-parsed, never tail-merged")
    }

    // MARK: - Codex incremental fold (cumulative counters resume from the cached state)

    private func codexMeta(id: String) -> String {
        #"{"timestamp":"2026-06-20T09:59:00Z","type":"session_meta","payload":{"id":"\#(id)"}}"#
    }
    private func codexTurn(model: String) -> String {
        #"{"timestamp":"2026-06-20T09:59:30Z","type":"turn_context","payload":{"model":"\#(model)"}}"#
    }
    private func codexCount(ts: String, input: Int, cached: Int, output: Int,
                            usedPct: Double? = nil) -> String {
        let rl = usedPct.map {
            #","rate_limits":{"primary":{"used_percent":\#($0),"window_minutes":300},"plan_type":"pro"}"#
        } ?? ""
        return #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output)}}\#(rl)}}"#
    }

    /// Codex counters are CUMULATIVE, so a tail parse is only correct if the fold resumes
    /// from the cached baselines/session/seq. Appends cover both regimes — ordinary growth
    /// and a compaction reset (counters shrink) — and the cache must match the one-shot
    /// parse exactly: same deltas, continuing seq, same session id, and the appended
    /// rate_limits snapshot surfacing.
    func testCodexCacheResumesFoldAcrossAppends() throws {
        let url = try write("rollout-2026-06-20T10-00-00-00000000-0000-0000-0000-000000000000.jsonl", [
            codexMeta(id: "sess-1"),
            codexTurn(model: "gpt-5.3-codex"),
            codexCount(ts: "2026-06-20T10:00:00Z", input: 100, cached: 40, output: 10),
        ])
        let name = url.lastPathComponent
        let cache = RecordCache()
        XCTAssertEqual(cache.codexRecords(for: [fresh(name)]).records.count, 1)

        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data(([
            codexCount(ts: "2026-06-20T10:05:00Z", input: 250, cached: 90, output: 30, usedPct: 42),
            codexCount(ts: "2026-06-20T10:10:00Z", input: 40, cached: 5, output: 5),  // compaction reset
        ].joined(separator: "\n") + "\n").utf8))
        try handle.close()

        let out = cache.codexRecords(for: [fresh(name)])
        let oneShot = CodexLogReader.parseFile(fresh(name))
        XCTAssertEqual(out.records.map(\.usage.sum), oneShot.records.map(\.usage.sum),
                       "deltas match the one-shot fold — baselines resumed, reset handled")
        XCTAssertEqual(out.records.map(\.requestId), oneShot.records.map(\.requestId),
                       "seq continues across the incremental boundary")
        XCTAssertEqual(out.records.map(\.messageId), oneShot.records.map(\.messageId),
                       "the session id established before the boundary survives it")
        XCTAssertEqual(out.codexRateLimits?.primary?.usedPercent, 42,
                       "the appended official snapshot surfaces")
    }

    /// `parsedBytes` persists: a FRESH instance (relaunch) serves the cached prefix and
    /// parses only the tail — proven with the same corrupt-the-prefix trick as above.
    func testPersistentCacheTailParsesAfterRelaunch() throws {
        let store = dir.appendingPathComponent("record-cache.jsonl")
        let line1 = assistantLine(id: "m1", req: "r1")
        let url = try write("s.jsonl", [line1])
        _ = RecordCache(storeURL: store).records(for: [fresh("s.jsonl")])

        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 0)
        handle.write(Data(String(repeating: "X", count: line1.utf8.count).utf8))
        handle.seekToEndOfFile()
        handle.write(Data((assistantLine(id: "m2", req: "r2") + "\n").utf8))
        try handle.close()

        let warm = RecordCache(storeURL: store)
        let out = warm.records(for: [fresh("s.jsonl")])
        XCTAssertEqual(out.records.map(\.messageId), ["m1", "m2"],
                       "a fresh instance resumed from the persisted offset, not a re-parse")
        XCTAssertEqual(out.malformed, 0)
    }

    /// A store entry with an impossible resume offset — the store is user-editable by design,
    /// so a decoded entry is still input data — is dropped at hydration and its file simply
    /// re-parses. Before the guard, a negative `parsedBytes` reached the byte scanner (an
    /// out-of-bounds read); with only the scanner's clamp it would re-parse from 0 on top of
    /// the cached records, duplicating them — so this pins the exact single-`m1` result.
    func testPersistentCacheRejectsImpossiblePersistedOffset() throws {
        let store = dir.appendingPathComponent("record-cache.jsonl")
        let url = try write("s.jsonl", [assistantLine(id: "m1", req: "r1")])
        _ = RecordCache(storeURL: store).records(for: [fresh("s.jsonl")])

        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        let text = try String(contentsOf: store, encoding: .utf8)
        XCTAssertTrue(text.contains(#""parsedBytes":\#(size)"#), "test premise: the offset is in the store")
        try text.replacingOccurrences(of: #""parsedBytes":\#(size)"#, with: #""parsedBytes":-5"#)
            .write(to: store, atomically: true, encoding: .utf8)

        let out = RecordCache(storeURL: store).records(for: [fresh("s.jsonl")])
        XCTAssertEqual(out.records.map(\.messageId), ["m1"],
                       "the poisoned entry was dropped and the file re-parsed — no crash, no duplicates")
        XCTAssertEqual(out.malformed, 0)
    }

    /// The scanner's own defense: an out-of-range offset degrades to a bounded scan, never an
    /// out-of-bounds read (persisted offsets are validated upstream, but bad input data must
    /// not be able to crash the process from any path).
    func testCompleteLinesClampsOutOfRangeOffsets() {
        let data = Data("a\n".utf8)
        let negative = JSONLText.completeLines(in: data, from: -7)
        XCTAssertEqual(negative.lines, ["a"])
        XCTAssertEqual(negative.consumed, 2)

        let pastEnd = JSONLText.completeLines(in: data, from: 99)
        XCTAssertEqual(pastEnd.lines, [])
        XCTAssertEqual(pastEnd.consumed, 2, "clamped to the data's end")
        XCTAssertNil(pastEnd.partial)
    }

    // MARK: - v3 store format

    /// The store is JSONL — a version header line, then one entry per line (so flushing
    /// encodes one entry at a time, never a boxed tree of all history) — and a successful
    /// flush deletes the superseded v1/v2 blob stores.
    func testPersistentStoreIsJSONLAndCleansUpOldVersions() throws {
        let storeDir = dir.appendingPathComponent("cachedir")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let store = storeDir.appendingPathComponent("record-cache-v3.jsonl")
        let v1 = storeDir.appendingPathComponent("record-cache-v1.json")
        let v2 = storeDir.appendingPathComponent("record-cache-v2.json")
        try "old".write(to: v1, atomically: true, encoding: .utf8)
        try "old".write(to: v2, atomically: true, encoding: .utf8)

        let url = try write("s.jsonl", [assistantLine(id: "m1", req: "r1")])
        _ = RecordCache(storeURL: store).records(for: [url])

        XCTAssertFalse(FileManager.default.fileExists(atPath: v1.path), "superseded v1 store deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: v2.path), "superseded v2 store deleted")
        let lines = try String(contentsOf: store, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.first, #"{"version":3}"#, "human-checkable version header")
        XCTAssertEqual(lines.count, 2, "header + one entry: one JSON object per line")
    }

    // MARK: - JSONLText.completeLines (the byte-level cutter under all of the above)

    /// Only newline-terminated lines are consumed; the trailing fragment comes back separately,
    /// and resuming from `consumed` on the grown data yields the completed line whole.
    func testCompleteLinesConsumesOnlyTerminatedLines() {
        let cut = JSONLText.completeLines(in: Data("a\r\nb\nc".utf8), from: 0)
        XCTAssertEqual(cut.lines, ["a", "b"], "CRLF and LF both terminate; the fragment is not a line")
        XCTAssertEqual(cut.consumed, 5, #"consumed ends after "a\r\nb\n""#)
        XCTAssertEqual(cut.partial, "c")

        let grown = JSONLText.completeLines(in: Data("a\r\nb\nc-more\n".utf8), from: cut.consumed)
        XCTAssertEqual(grown.lines, ["c-more"], "the completed fragment re-parses whole from `consumed`")
        XCTAssertNil(grown.partial)
    }
}
