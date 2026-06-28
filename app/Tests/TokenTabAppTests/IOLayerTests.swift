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
}
