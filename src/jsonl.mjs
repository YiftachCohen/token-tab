// Token Tab — how a JSONL file is cut into lines. Swift twin: `JSONLText.swift`.
//
// Both readers (Claude + Codex) stream through this, so the CLI cuts lines exactly where
// the app does, and only there: on ASCII newlines (LF, CR, CRLF).
//
// This exists because Unicode line-breaking is wider than JSONL's. The Unicode
// line-boundary set adds U+0085 NEL, U+2028 LINE SEPARATOR and U+2029 PARAGRAPH
// SEPARATOR — and `JSON.stringify` emits all three RAW rather than escaping them, so any
// assistant turn quoting a file that contains one (minified JS and exported JSON are the
// usual sources) is a single physical line that a Unicode-aware splitter cuts into
// several. Each fragment is truncated JSON, every fragment fails to decode, and the whole
// record's tokens vanish — silently, since the malformed counter is never rendered.
//
// `readline` used to be safe here (it documented `/\r?\n|\r(?!\n)/`), which is why both
// readers used it. It isn't any more: as of Node 24 it also breaks on U+2028/U+2029, so on
// a current runtime the CLI dropped exactly the records the app's `JSONLText` was written
// to keep. Hence an explicit scan rather than a borrowed one — the rule is ours to hold.
//
// Streaming, not `readFileSync().split()`: a cold parse walks the whole log history, and
// the raw lines carry message content, which must not sit in memory as a block.

import { createReadStream } from "node:fs";

const LF = 0x0a;
const CR = 0x0d;

/**
 * Yield each non-empty line of a UTF-8 text file, split on ASCII newlines only.
 *
 * A CRLF pair and any run of blank lines collapse away, matching `JSONLText.lines` and what
 * both callers already do with an empty line. Multi-byte characters straddling a read
 * boundary are handled by the stream's own decoder; undecodable bytes become U+FFFD and
 * cost their own line at most, never the file.
 *
 * @param {string} path
 * @returns {AsyncGenerator<string>}
 */
export async function* jsonlLines(path) {
  const stream = createReadStream(path, { encoding: "utf8" });
  let buf = ""; // the trailing not-yet-terminated line
  let scanned = 0; // buf[0..scanned) is known to hold no newline
  for await (const chunk of stream) {
    buf += chunk;
    let start = 0;
    for (let i = scanned; i < buf.length; i++) {
      const c = buf.charCodeAt(i);
      if (c !== LF && c !== CR) continue;
      if (i > start) yield buf.slice(start, i);
      start = i + 1;
    }
    buf = buf.slice(start);
    scanned = buf.length;
  }
  if (buf.length) yield buf;
}
