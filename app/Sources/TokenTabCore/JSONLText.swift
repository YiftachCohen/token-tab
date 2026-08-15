// Token Tab — how a JSONL file is cut into lines.
//
// PURE: string in, lines out — no I/O. Shared by both readers (Claude + Codex) so the
// app cuts lines exactly where the JS engine does, and only there. JS twin: `src/jsonl.mjs`.
//
// This exists because Foundation's line-breaking is Unicode-aware and JSONL's is not.
// `String.enumerateLines` (and `Character.isNewline`, and `String.split(whereSeparator:
// \.isNewline)`) use the Unicode line-boundary set: LF, CR, CRLF **plus U+0085 NEL,
// U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR**. JSONL is cut on ASCII newlines
// only. (Node's `readline` used to be, so the JS engine borrowed its rule; as of Node 24
// it breaks on U+2028/U+2029 too, and `src/jsonl.mjs` now scans explicitly — both engines
// state the rule rather than inherit it.)
//
// Those three extra separators appear inside real log lines: `JSON.stringify` emits them
// raw rather than escaping them, so any assistant turn that quotes a file containing one
// (minified JS and exported JSON are the usual sources) is ONE physical line that
// Foundation cuts into several. Each fragment is truncated JSON, every fragment fails to
// decode, and the whole record's tokens vanish from the app while the CLI counts them —
// silently, since the malformed counter is never rendered.
//
// So: split on LF/CR only. A CRLF pair and any run of blank lines collapse away, which is
// what both callers already do with an empty line.
//
// N.B. `text.split(separator: "\n")` is NOT a correct spelling of this: Swift's Character
// is a grapheme cluster and "\r\n" is a SINGLE Character, so splitting on "\n" silently
// fails to break a CRLF file at all. Hence the scalar-level walk.

import Foundation

public enum JSONLText {
    /// Cut JSONL text into non-empty lines on ASCII newlines (LF, CR, CRLF) only.
    public static func lines(_ text: String) -> [String] {
        let lf: UInt32 = 0x0A
        let cr: UInt32 = 0x0D
        var out: [String] = []
        var current = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            if u.value == lf || u.value == cr {
                if !current.isEmpty {
                    out.append(String(current))
                    current = String.UnicodeScalarView()
                }
            } else {
                current.append(u)
            }
        }
        if !current.isEmpty { out.append(String(current)) }
        return out
    }

    /// The byte-level twin of `lines(_:)`, for file data read (or mapped) straight from disk.
    ///
    /// Cuts `data` from `offset` on the same ASCII newlines (LF, CR, CRLF) — 0x0A/0x0D bytes
    /// never occur inside a multi-byte UTF-8 sequence, so a byte scan cuts exactly where the
    /// scalar walk does — and decodes each line lossily (U+FFFD for damaged bytes), matching
    /// `String(decoding:as:)` over the whole file. Two things `lines(_:)` can't offer:
    ///
    /// - A one-line memory bound: `body` is called with each line DURING the scan, so a caller
    ///   that parses in place holds one decoded line at a time — never the whole file as a
    ///   String, and never an array of every line. (That bound is the point: on a cold parse
    ///   the raw lines include message content, which must not sit in memory as a block.)
    /// - Incremental consumption: `consumed` is the offset just past the last newline byte —
    ///   only COMPLETE lines are consumed, and the trailing not-yet-terminated fragment (a line
    ///   still being appended) comes back separately as `partial`. A caller that resumes from
    ///   `consumed` next time re-sees that fragment once its terminator arrives, whole.
    ///
    /// `offset` must lie on a line boundary of the SAME content (0, or a previous `consumed`);
    /// an out-of-range offset is clamped, never trapped — a persisted offset is input data, and
    /// bad input data must degrade to a re-parse, not a crash.
    /// For any full read, the lines seen by `body` plus `partial` equal `lines(_:)` of the
    /// decoded text.
    public static func enumerateCompleteLines(in data: Data, from offset: Int,
                                              _ body: (String) -> Void)
        -> (consumed: Int, partial: String?) {
        let count = data.count
        let offset = min(max(0, offset), count)   // clamp: see doc comment
        guard offset < count else { return (offset, nil) }
        var consumed = offset
        var partial: String? = nil
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let buf = raw.bindMemory(to: UInt8.self)
            var start = offset
            for i in offset..<count {
                let b = buf[i]
                guard b == 0x0A || b == 0x0D else { continue }
                if i > start {
                    body(String(decoding: UnsafeBufferPointer(rebasing: buf[start..<i]),
                                as: UTF8.self))
                }
                start = i + 1
                consumed = i + 1
            }
            if start < count {
                partial = String(decoding: UnsafeBufferPointer(rebasing: buf[start..<count]),
                                 as: UTF8.self)
            }
        }
        return (consumed, partial)
    }

    /// Array-collecting convenience over `enumerateCompleteLines` — for small inputs and
    /// tests. Real parse paths must use the enumerator: collecting defeats the one-line
    /// memory bound.
    public static func completeLines(in data: Data, from offset: Int)
        -> (lines: [String], consumed: Int, partial: String?) {
        var lines: [String] = []
        let r = enumerateCompleteLines(in: data, from: offset) { lines.append($0) }
        return (lines, r.consumed, r.partial)
    }
}
