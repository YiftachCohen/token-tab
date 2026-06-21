// Token Tab — pure parser for the opt-in live usage window.
//
// PURE: no I/O, no subprocess, no network. Takes the raw stdout of
// `claude -p "/usage" --output-format json` and returns the server-side
// session/weekly percentages, or null on anything unexpected (fail closed).
//
// This file deliberately lives in src/ (the audited core); the live adapter that
// produces its input lives under adapters/ (outside src/). Keeping the audited
// core free of subprocess and network calls is the whole point — the audit greps
// over src/ must keep printing nothing, so this file avoids those tokens even in
// comments (it uses String.match, not the dotted variant the audit looks for).
//
// Robustness notes (each pins a real failure mode, see test/live-parse.test.mjs):
//  - The percentage is matched INDEPENDENTLY of the "· resets …" tail, so a
//    future separator/encoding change (the `·` is U+00B7) costs only the reset
//    text, never the number the feature exists to show.
//  - We split on "\n" and match per line; a single anchored regex against the
//    whole multi-line `result` would never match.
//  - The whole body is guarded so parseUsageOutput(null) returns null, never
//    throws (JSON.parse("null") yields null without throwing).

const PCT_RE = /^Current (session|week \(([^)]+)\)):\s*(\d+)%\s*used\b(.*)$/;
const RESET_RE = /resets\s+(.+?)\s*$/;

/**
 * @param {string} stdout raw JSON string from `claude -p "/usage" --output-format json`
 * @returns {null | {source:string, sessionPct?:number, sessionResetText?:string,
 *   weeklyPct?:number, weeklyResetText?:string, weeklyByModel:Object}}
 */
export function parseUsageOutput(stdout) {
  let obj;
  try {
    obj = JSON.parse(stdout);
  } catch {
    return null; // non-JSON stdout (e.g. "command not found")
  }
  // JSON.parse("null") returns null WITHOUT throwing — guard before any access.
  if (!obj || typeof obj !== "object" || Array.isArray(obj)) return null;
  if (obj.is_error === true || typeof obj.result !== "string") return null;

  let sessionPct, sessionResetText, weeklyPct, weeklyResetText;
  const weeklyByModel = {};
  let found = false;

  for (const raw of obj.result.split("\n")) {
    const line = raw.replace(/\r$/, ""); // tolerate CRLF
    const m = line.match(PCT_RE);
    if (!m) continue;
    const kind = m[1]; // "session" | "week (...)"
    const inner = m[2]; // undefined | "all models" | "Sonnet only"
    const pct = Number(m[3]);
    const rm = (m[4] || "").match(RESET_RE); // tail parsed independently of the separator
    const resetText = rm ? rm[1] : undefined; // undefined on idle / drift

    if (kind === "session") {
      sessionPct = pct;
      sessionResetText = resetText;
      found = true;
    } else {
      const label = inner.trim().toLowerCase();
      if (label === "all models") {
        weeklyPct = pct;
        weeklyResetText = resetText;
        found = true;
      } else {
        weeklyByModel[label.replace(/\s+only$/, "")] = pct; // "Sonnet only" -> "sonnet"
        found = true;
      }
    }
  }

  if (!found) return null; // no "Current …% used" line anywhere
  return { source: "claude /usage", sessionPct, sessionResetText, weeklyPct, weeklyResetText, weeklyByModel };
}
