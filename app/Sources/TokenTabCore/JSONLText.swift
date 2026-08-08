// Token Tab — how a JSONL file is cut into lines.
//
// PURE: string in, lines out — no I/O. Shared by both readers (Claude + Codex) so the
// app cuts lines exactly where the JS engine does, and only there.
//
// This exists because Foundation's line-breaking is Unicode-aware and the JS engine's is
// not. `String.enumerateLines` (and `Character.isNewline`, and `String.split(whereSeparator:
// \.isNewline)`) use the Unicode line-boundary set: LF, CR, CRLF **plus U+0085 NEL,
// U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR**. Node's readline splits on
// `/\r?\n|\r(?!\n)/` — ASCII newlines only.
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
}
