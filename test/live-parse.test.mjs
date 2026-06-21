// Golden-fixture tests for the live-usage parser (src/live-parse.mjs).
//
// Pure-parser only: we NEVER spawn `claude` here. The fixtures are the exact
// strings `claude -p "/usage" --output-format json` prints (the `·` is U+00B7).
// Each case pins a failure mode the /autoplan eng review flagged. Run: `node --test`.

import { test } from "node:test";
import assert from "node:assert/strict";
import { parseUsageOutput } from "../src/live-parse.mjs";

// Wrap result text the way the real command does.
const envelope = (result, over = {}) =>
  JSON.stringify({
    type: "result",
    is_error: false,
    result,
    total_cost_usd: 0,
    usage: { input_tokens: 0, output_tokens: 0 },
    ...over,
  });

const ACTIVE = [
  "You are currently using your subscription to power your Claude Code usage",
  "",
  "Current session: 7% used · resets Jun 21 at 9:49pm (Europe/Rome)",
  "Current week (all models): 8% used · resets Jun 27 at 6:59am (Europe/Rome)",
  "Current week (Sonnet only): 0% used",
  "",
  "What's contributing to your limits usage?",
  "Approximate, based on local sessions on this machine — does not include other devices or claude.ai.",
].join("\n");

test("active fixture: session + weekly + per-model parse", () => {
  const a = parseUsageOutput(envelope(ACTIVE));
  assert.equal(a.sessionPct, 7);
  assert.equal(a.sessionResetText, "Jun 21 at 9:49pm (Europe/Rome)");
  assert.equal(a.weeklyPct, 8);
  assert.equal(a.weeklyResetText, "Jun 27 at 6:59am (Europe/Rome)");
  assert.deepEqual(a.weeklyByModel, { sonnet: 0 });
  assert.equal(a.source, "claude /usage");
});

test("is_error: true envelope -> null", () => {
  assert.equal(parseUsageOutput(envelope(ACTIVE, { is_error: true })), null);
});

test("non-JSON stdout -> null", () => {
  assert.equal(parseUsageOutput("command not found: claude"), null);
});

test("valid JSON but no usage lines -> null", () => {
  assert.equal(parseUsageOutput(envelope("just some prose, no current usage here")), null);
});

test("empty string -> null", () => {
  assert.equal(parseUsageOutput(""), null);
});

test("null input -> null AND does not throw (JSON.parse(null) returns null)", () => {
  assert.doesNotThrow(() => parseUsageOutput(null));
  assert.equal(parseUsageOutput(null), null);
});

test("idle session (no resets tail): pct parsed, resetText undefined", () => {
  const a = parseUsageOutput(envelope("Current session: 3% used"));
  assert.equal(a.sessionPct, 3);
  assert.equal(a.sessionResetText, undefined);
});

test("separator drift (· -> hyphen): the percentage still parses", () => {
  // The whole point of two-regex parsing: a separator change must not kill the %.
  const drift = ACTIVE.replace(/·/g, "-");
  const a = parseUsageOutput(envelope(drift));
  assert.equal(a.sessionPct, 7, "% survives a separator change");
  assert.equal(a.weeklyPct, 8);
});

test("unrecognized tail (no 'resets' word): pct survives, resetText undefined", () => {
  const a = parseUsageOutput(envelope("Current session: 7% used until tomorrow"));
  assert.equal(a.sessionPct, 7);
  assert.equal(a.sessionResetText, undefined);
});

test("'all models' fills weeklyPct and never leaks into weeklyByModel", () => {
  const a = parseUsageOutput(envelope(ACTIVE));
  assert.equal(a.weeklyPct, 8);
  assert.equal("all models" in a.weeklyByModel, false);
  assert.deepEqual(Object.keys(a.weeklyByModel), ["sonnet"]);
});

test("' only' is stripped and lowercased: 'Sonnet only' -> 'sonnet'", () => {
  const a = parseUsageOutput(envelope("Current week (Sonnet only): 4% used"));
  assert.deepEqual(a.weeklyByModel, { sonnet: 4 });
  assert.equal("sonnet only" in a.weeklyByModel, false);
});

test("multiple per-model weeklies: sonnet + opus", () => {
  const result = [
    "Current week (all models): 8% used · resets Jun 27 at 6:59am (Europe/Rome)",
    "Current week (Sonnet only): 0% used",
    "Current week (Opus only): 12% used",
  ].join("\n");
  const a = parseUsageOutput(envelope(result));
  assert.deepEqual(a.weeklyByModel, { sonnet: 0, opus: 12 });
  assert.equal(a.weeklyPct, 8);
});

test("CRLF line endings parse identically", () => {
  const a = parseUsageOutput(envelope(ACTIVE.replace(/\n/g, "\r\n")));
  assert.equal(a.sessionPct, 7);
  assert.equal(a.sessionResetText, "Jun 21 at 9:49pm (Europe/Rome)", "no trailing \\r in reset text");
  assert.deepEqual(a.weeklyByModel, { sonnet: 0 });
});

test("over-limit percentage (>100) parses, not clamped", () => {
  const a = parseUsageOutput(envelope("Current session: 103% used · resets soon"));
  assert.equal(a.sessionPct, 103);
});

test("session absent but weekly present -> weekly parses, session undefined", () => {
  const a = parseUsageOutput(envelope("Current week (all models): 8% used · resets Jun 27 at 6:59am (Europe/Rome)"));
  assert.equal(a.weeklyPct, 8);
  assert.equal(a.sessionPct, undefined);
});

test("weekly absent but session present -> session parses, weekly undefined", () => {
  const a = parseUsageOutput(envelope("Current session: 7% used · resets Jun 21 at 9:49pm (Europe/Rome)"));
  assert.equal(a.sessionPct, 7);
  assert.equal(a.weeklyPct, undefined);
  assert.deepEqual(a.weeklyByModel, {});
});
