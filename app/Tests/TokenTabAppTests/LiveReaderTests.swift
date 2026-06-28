// Decode-path tests for LiveReader — the sandboxed app's reader for the opt-in live cache.
//
// CONTRACT: the JSON in `fullReadingJSON` below is the VERBATIM output of serializeLive()
// in adapters/write-live.mjs (pinned on the JS side by test/write-live.test.mjs). If the
// writer's shape changes, update this literal here too — that is the whole point of this
// test: it fails when the JS writer and the Swift reader drift apart. Synthetic values only.

import XCTest
@testable import TokenTab
@testable import TokenTabCore

final class LiveReaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokentab-live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Write `json` to <dir>/.token-tab-live.json (the path LiveReader.read looks at).
    private func writeCache(_ json: String) throws {
        try json.write(to: LiveReader.cacheURL(logDir: dir), atomically: true, encoding: .utf8)
    }

    /// VERBATIM serializeLive() output (see test/write-live.test.mjs). Do not "tidy" it.
    private let fullReadingJSON = """
    {
      "schema": 1,
      "source": "claude /usage",
      "capturedAt": "2026-06-23T10:15:00.000Z",
      "sessionPct": 9,
      "sessionResetText": "12:29am (Europe/Rome)",
      "weeklyPct": 18,
      "weeklyResetText": "Jun 27 at 6:59am (Europe/Rome)",
      "weeklyByModel": {
        "sonnet": 0
      }
    }
    """

    // MARK: - The JS↔Swift contract

    /// The full verbatim writer output decodes field-for-field. This is the canary: if
    /// serializeLive() drifts, this assertion (or `fullReadingJSON`) goes red.
    func testDecodesTheFullWriterContract() throws {
        try writeCache(fullReadingJSON)
        let live = try XCTUnwrap(LiveReader.read(logDir: dir))
        XCTAssertEqual(live.sessionPct, 9)
        XCTAssertEqual(live.sessionResetText, "12:29am (Europe/Rome)")
        XCTAssertEqual(live.weeklyPct, 18)
        XCTAssertEqual(live.weeklyResetText, "Jun 27 at 6:59am (Europe/Rome)")
        XCTAssertEqual(live.weeklyByModel, ["sonnet": 0])
        XCTAssertNotNil(live.capturedAt, "fractional-seconds capturedAt must parse")
    }

    // MARK: - Date robustness

    /// capturedAt without fractional seconds still parses via the isoNoFrac fallback.
    func testCapturedAtWithoutFractionalSecondsParses() throws {
        try writeCache("""
        {
          "schema": 1,
          "source": "claude /usage",
          "capturedAt": "2026-06-23T10:15:00Z",
          "sessionPct": 9,
          "sessionResetText": "12:29am (Europe/Rome)",
          "weeklyPct": 18,
          "weeklyResetText": "Jun 27 at 6:59am (Europe/Rome)",
          "weeklyByModel": {
            "sonnet": 0
          }
        }
        """)
        let live = try XCTUnwrap(LiveReader.read(logDir: dir))
        XCTAssertNotNil(live.capturedAt, "non-fractional capturedAt must parse via the isoNoFrac fallback")
    }

    // MARK: - Partial readings

    /// A lone session % is a usable reading — weekly stays nil, the reading is not absent.
    func testLoneSessionPctIsEnough() throws {
        try writeCache(#"{"schema":1,"sessionPct":3}"#)
        let live = try XCTUnwrap(LiveReader.read(logDir: dir))
        XCTAssertEqual(live.sessionPct, 3)
        XCTAssertNil(live.weeklyPct)
    }

    // MARK: - Fail closed

    /// No session AND no weekly % is useless — read() treats it as absent (nil).
    func testNoPercentagesIsTreatedAsAbsent() throws {
        try writeCache(#"{"schema":1,"weeklyByModel":{}}"#)
        XCTAssertNil(LiveReader.read(logDir: dir))
    }

    /// No cache file at all → nil (the common case before the sidecar has ever run).
    func testMissingFileReturnsNil() {
        XCTAssertNil(LiveReader.read(logDir: dir))
    }

    /// A half-written or corrupt file decodes to nil, never throws.
    func testMalformedJSONReturnsNil() throws {
        try writeCache("{ not valid json")
        XCTAssertNil(LiveReader.read(logDir: dir))
    }

    // MARK: - Forward compatibility

    /// The schema field is informational — decoding must not gate on its value, so an
    /// unknown future schema still yields the populated reading (forward-compatible).
    func testUnknownSchemaStillDecodes() throws {
        try writeCache("""
        {
          "schema": 999,
          "source": "claude /usage",
          "capturedAt": "2026-06-23T10:15:00.000Z",
          "sessionPct": 9,
          "sessionResetText": "12:29am (Europe/Rome)",
          "weeklyPct": 18,
          "weeklyResetText": "Jun 27 at 6:59am (Europe/Rome)",
          "weeklyByModel": {
            "sonnet": 0
          }
        }
        """)
        let live = try XCTUnwrap(LiveReader.read(logDir: dir))
        XCTAssertEqual(live.sessionPct, 9)
        XCTAssertEqual(live.weeklyPct, 18)
    }
}
