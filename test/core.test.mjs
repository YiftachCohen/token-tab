// Golden-fixture tests for the parser core.
//
// These ARE the test oracle (NOT live ccusage — that's version-coupled and reads
// ever-changing live logs). Each fixture pins an edge case the /autoplan eng
// review found on real disk. Run: `node --test`
//
// Fixtures use synthetic values only — no real prompt/response text.

import { test } from "node:test";
import assert from "node:assert/strict";
import { aggregate, recordFromLine, classifySurface, normalizeModel, usageSum } from "../src/core.mjs";

const u = (input, cc, cr, output) => ({
  input_tokens: input,
  cache_creation_input_tokens: cc,
  cache_read_input_tokens: cr,
  output_tokens: output,
});
const rec = (over = {}) => ({
  messageId: "m1",
  requestId: "r1",
  model: "claude-opus-4-8",
  usage: u(10, 20, 30, 5),
  timestamp: "2026-06-20T12:00:00Z",
  isSidechain: false,
  ...over,
});

test("usageSum includes all four classes (cache_read must count)", () => {
  assert.equal(usageSum(u(1, 2, 4, 8)), 15);
  assert.equal(usageSum(undefined), 0);
});

test("single record aggregates totals + surface + model", () => {
  const a = aggregate([rec()]);
  assert.equal(a.total, 65);
  assert.deepEqual(a.byClass, { input: 10, cacheCreate: 20, cacheRead: 30, output: 5 });
  assert.equal(a.bySurface.subscription, 65);
  assert.equal(a.byModel["claude-opus-4-8"], 65);
  assert.equal(a.dedup.counted, 1);
});

test("dedup KEEP-LAST: streaming partials, output grows, final wins", () => {
  const partial = rec({ usage: u(5, 1151, 34462, 2) }); // sum 35620
  const final = rec({ usage: u(5, 1151, 34462, 227) }); // sum 35845
  const a = aggregate([partial, final]);
  assert.equal(a.dedup.counted, 1, "same key counted once");
  assert.equal(a.dedup.duplicatesDropped, 1);
  assert.equal(a.dedup.collisionsDifferingTotals, 1, "differing totals flagged");
  assert.equal(a.total, 35845, "keep-last: final (larger output) wins");
  assert.equal(a.byClass.output, 227);
});

test("identical duplicates collapse to one, no collision flag", () => {
  const a = aggregate([rec(), rec()]);
  assert.equal(a.dedup.counted, 1);
  assert.equal(a.dedup.duplicatesDropped, 1);
  assert.equal(a.dedup.collisionsDifferingTotals, 0);
});

test("missing requestId -> unique key, always counted, marked approximate", () => {
  const a = aggregate([
    rec({ messageId: "m9", requestId: undefined }),
    rec({ messageId: "m9", requestId: undefined }),
  ]);
  assert.equal(a.dedup.counted, 2, "never deduped away when id missing");
  assert.equal(a.approximate, true);
});

test("sidechain usage is real spend (isSidechain is NOT a filter)", () => {
  const a = aggregate([rec({ messageId: "m1" }), rec({ messageId: "m2", requestId: "r2", isSidechain: true })]);
  assert.equal(a.dedup.counted, 2);
  assert.equal(a.total, 130);
});

test("surface routing", () => {
  assert.equal(classifySurface("claude-opus-4-8"), "subscription");
  assert.equal(classifySurface("claude-fable-5"), "subscription");
  assert.equal(classifySurface("sonnet"), "subscription");
  assert.equal(classifySurface("us.anthropic.claude-3-5-sonnet-20241022-v2:0"), "bedrock");
  assert.equal(classifySurface("anthropic.claude-3-haiku-20240307-v1:0"), "bedrock");
  assert.equal(classifySurface("<synthetic>"), "untracked");
  assert.equal(classifySurface("gpt-5.5"), "untracked");
});

test("[1m] suffix normalizes to its own tier but same surface", () => {
  assert.deepEqual(normalizeModel("claude-opus-4-8[1m]"), { base: "claude-opus-4-8", oneM: true });
  assert.equal(classifySurface("claude-opus-4-8[1m]"), "subscription");
});

test("untracked model still counts tokens (never silently drop)", () => {
  const a = aggregate([rec({ model: "totally-unknown-model", messageId: "mx", requestId: "rx" })]);
  assert.equal(a.total, 65, "unknown model -> tokens still counted");
  assert.equal(a.bySurface.untracked, 65);
  assert.equal(a.untracked.requests, 1);
});

test("recordFromLine filters to assistant turns with usage", () => {
  assert.equal(recordFromLine({ type: "user", message: { content: "secret" } }), null);
  assert.equal(recordFromLine({ type: "assistant", message: { id: "m", model: "claude-x" } }), null, "no usage -> null");
  const r = recordFromLine({
    type: "assistant",
    requestId: "r1",
    timestamp: "2026-06-20T12:00:00Z",
    isSidechain: true,
    message: { id: "m1", model: "claude-opus-4-8", content: "NEVER READ THIS", usage: u(1, 0, 0, 2) },
  });
  assert.equal(r.messageId, "m1");
  assert.equal(r.requestId, "r1");
  assert.equal(r.isSidechain, true);
  assert.equal(r.content, undefined, "content is never carried out of the parser");
});

test("usage window: active block; reset exact; no guessed % without a configured cap", () => {
  const now = new Date("2026-06-20T18:00:00Z");
  const records = [
    rec({ messageId: "y", requestId: "yr", timestamp: "2026-06-19T10:00:00Z", usage: u(1000, 0, 0, 0) }), // completed block
    rec({ messageId: "a1", requestId: "ar1", timestamp: "2026-06-20T16:30:00Z", usage: u(200, 0, 0, 0) }),
    rec({ messageId: "a2", requestId: "ar2", timestamp: "2026-06-20T17:00:00Z", usage: u(100, 0, 0, 0) }),
  ];
  const a = aggregate(records, { now });
  assert.equal(a.window.active, true);
  assert.equal(a.window.tokens, 300, "active block tokens");
  assert.equal(a.window.calibratedCap, 1000, "busiest completed block is exposed (info only)");
  assert.equal(a.window.capSource, "none");
  assert.equal(a.window.pct, null, "calibrated cap is NOT used as a denominator — would over-report");
  // reset anchors to the EXACT first message of the block (16:30Z), not the top of the hour.
  assert.equal(a.window.resetAt, new Date("2026-06-20T21:30:00Z").getTime());
  assert.equal(a.window.msToReset, 3.5 * 60 * 60 * 1000, "21:30 - 18:00 = 3h30m");
});

test("usage window: explicit cap overrides calibration", () => {
  const now = new Date("2026-06-20T18:00:00Z");
  const records = [
    rec({ messageId: "y", requestId: "yr", timestamp: "2026-06-19T10:00:00Z", usage: u(1000, 0, 0, 0) }),
    rec({ messageId: "a1", requestId: "ar1", timestamp: "2026-06-20T16:30:00Z", usage: u(200, 0, 0, 0) }),
    rec({ messageId: "a2", requestId: "ar2", timestamp: "2026-06-20T17:00:00Z", usage: u(100, 0, 0, 0) }),
  ];
  const a = aggregate(records, { now, cap: 600 });
  assert.equal(a.window.capSource, "config");
  assert.equal(a.window.pct, 50, "300 / 600");
});

test("usage window: idle when last activity is older than the block", () => {
  const now = new Date("2026-06-20T18:00:00Z");
  const a = aggregate([rec({ messageId: "y", requestId: "yr", timestamp: "2026-06-19T10:00:00Z", usage: u(1000, 0, 0, 0) })], { now });
  assert.equal(a.window.active, false);
  assert.equal(a.window.tokens, 0);
  assert.equal(a.window.msToReset, null);
});

test("usage window: no cap basis -> pct is null, not a fake number", () => {
  const now = new Date("2026-06-20T18:00:00Z");
  const a = aggregate([rec({ messageId: "s", requestId: "sr", timestamp: "2026-06-20T17:30:00Z", usage: u(50, 0, 0, 0) })], { now });
  assert.equal(a.window.active, true);
  assert.equal(a.window.tokens, 50);
  assert.equal(a.window.capSource, "none");
  assert.equal(a.window.pct, null, "never invent a % without a cap basis");
});

test("rolling-5h window is absolute half-open (now-5h, now] — TZ independent", () => {
  const now = new Date("2026-06-20T18:00:00Z");
  const within = rec({ messageId: "a", requestId: "1", timestamp: "2026-06-20T15:00:00Z" }); // 3h ago
  const edgeOut = rec({ messageId: "b", requestId: "2", timestamp: "2026-06-20T12:30:00Z" }); // 5.5h ago
  const a = aggregate([within, edgeOut], { now });
  assert.equal(a.rolling5h, 65, "only the record inside 5h counts toward rolling window");
  assert.equal(a.total, 130, "both still in all-time total");
});
