// Golden tests for the dollars layer (src/pricing.mjs + the cost block in aggregate).
//
// Each case pins one rule the "estimate, never invent" promise depends on: per-class
// rates (cache-read != cache-write), [1m] and Bedrock id normalization, bare aliases,
// and unknown-model = tracked-tokens / untracked-price. Synthetic values only.

import { test } from "node:test";
import assert from "node:assert/strict";
import { aggregate } from "../src/core.mjs";
import { costOfUsage, ratesFor, canonicalModelId } from "../src/pricing.mjs";

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
  ...over,
});

// 1M tokens of each class, one at a time, so the rate IS the cost in dollars.
const oneMillion = { input: u(1e6, 0, 0, 0), cacheWrite: u(0, 1e6, 0, 0), cacheRead: u(0, 0, 1e6, 0), output: u(0, 0, 0, 1e6) };

test("each token class is priced by its own rate (cache-read != cache-write != input)", () => {
  // Opus 4.8: input $5/M, output $25/M, cache-write 1.25x input = $6.25, cache-read 0.10x = $0.50
  assert.equal(costOfUsage(oneMillion.input, "claude-opus-4-8").usd, 5);
  assert.equal(costOfUsage(oneMillion.output, "claude-opus-4-8").usd, 25);
  assert.equal(costOfUsage(oneMillion.cacheWrite, "claude-opus-4-8").usd, 6.25);
  assert.equal(costOfUsage(oneMillion.cacheRead, "claude-opus-4-8").usd, 0.5);
});

test("ratesFor derives the two cache rates from input; output is independent", () => {
  const r = ratesFor("claude-fable-5"); // input $10, output $50
  assert.deepEqual(r, { input: 10, cacheWrite: 12.5, cacheRead: 1, output: 50 });
  assert.equal(ratesFor("totally-unknown"), null);
});

test("[1m] tier shares the base rate (no long-context premium on current models)", () => {
  assert.equal(costOfUsage(oneMillion.input, "claude-opus-4-8[1m]").usd, 5);
  assert.equal(costOfUsage(oneMillion.input, "claude-fable-5[1m]").usd, 10);
});

test("Bedrock ids normalize to the list-price key", () => {
  assert.equal(canonicalModelId("us.anthropic.claude-opus-4-8-20251101-v1:0"), "claude-opus-4-8");
  assert.equal(canonicalModelId("anthropic.claude-sonnet-4-6"), "claude-sonnet-4-6");
  assert.equal(costOfUsage(oneMillion.input, "us.anthropic.claude-opus-4-8-v1:0").usd, 5);
});

test("dated snapshot suffix is stripped (haiku-4-5-20251001 -> haiku-4-5)", () => {
  assert.equal(canonicalModelId("claude-haiku-4-5-20251001"), "claude-haiku-4-5");
  assert.equal(costOfUsage(oneMillion.input, "claude-haiku-4-5-20251001").usd, 1);
});

test("bare family aliases resolve to the current model in that family", () => {
  assert.equal(costOfUsage(oneMillion.output, "sonnet").usd, 15); // -> sonnet-5
});

test("Sonnet 5 is priced at the $3/$15 list rate (intro discount not modeled)", () => {
  assert.equal(costOfUsage(oneMillion.input, "claude-sonnet-5").usd, 3);
  assert.equal(costOfUsage(oneMillion.output, "claude-sonnet-5").usd, 15);
  // "sonnet" now aliases to Sonnet 5, so canonicalization + alias agree.
  assert.equal(canonicalModelId("claude-sonnet-5"), "claude-sonnet-5");
});

test("older still-billable models are priced (Opus 4.1 higher tier, Opus/Sonnet 4.5, Haiku 3.5)", () => {
  // Opus 4.1 is the legacy $15/$75 tier — distinct from the current $5/$25 Opus rate.
  assert.equal(costOfUsage(oneMillion.input, "claude-opus-4-1").usd, 15);
  assert.equal(costOfUsage(oneMillion.output, "claude-opus-4-1").usd, 75);
  assert.equal(costOfUsage(oneMillion.input, "claude-opus-4-5").usd, 5);
  assert.equal(costOfUsage(oneMillion.input, "claude-sonnet-4-5").usd, 3);
  assert.equal(costOfUsage(oneMillion.input, "claude-3-5-haiku").usd, 0.8);
  // dated snapshot and Bedrock id both canonicalize to the base key before lookup
  assert.equal(costOfUsage(oneMillion.input, "claude-sonnet-4-5-20250929").usd, 3);
  assert.equal(costOfUsage(oneMillion.output, "anthropic.claude-sonnet-4-20250514-v1:0").usd, 15);
});

test("Haiku 3 has no published rate -> unpriced (honest unknown, never guessed)", () => {
  assert.equal(ratesFor("claude-3-haiku-20240307"), null);
  assert.equal(costOfUsage(u(1000, 0, 0, 1000), "claude-3-haiku-20240307").priced, false);
});

test("unknown model: priced=false, zero dollars (caller keeps the tokens)", () => {
  const r = costOfUsage(u(100, 0, 0, 50), "<synthetic>");
  assert.equal(r.priced, false);
  assert.equal(r.usd, 0);
});

test("aggregate cost block: total, per-model, and the unpriced gap", () => {
  const a = aggregate(
    [
      rec({ messageId: "a", requestId: "1", model: "claude-opus-4-8", usage: u(1e6, 0, 0, 0) }), // $5
      rec({ messageId: "b", requestId: "2", model: "claude-sonnet-4-6", usage: u(0, 0, 0, 1e6) }), // $15
      rec({ messageId: "c", requestId: "3", model: "<synthetic>", usage: u(100, 0, 0, 100) }), // unpriced, 200 tokens
    ],
    { cost: costOfUsage },
  );
  assert.equal(a.cost.total, 20, "$5 opus + $15 sonnet");
  assert.equal(a.cost.byModel["claude-opus-4-8"], 5);
  assert.equal(a.cost.byModel["claude-sonnet-4-6"], 15);
  assert.equal(a.cost.byModel["<synthetic>"], undefined, "unpriced model is not in byModel");
  assert.equal(a.cost.unpriced.requests, 1);
  assert.equal(a.cost.unpriced.tokens, 200, "unpriced tokens are still counted");
  assert.deepEqual(a.cost.unpriced.models, ["<synthetic>"]);
  assert.equal(a.total, 2000200, "all tokens, priced or not, still in the grand total");
});

test("no cost fn -> no cost block (default output byte-for-byte unchanged)", () => {
  const a = aggregate([rec()]);
  assert.equal(a.cost, undefined);
});

test("cost windows mirror the token windows (today/week/5h)", () => {
  const now = new Date("2026-06-20T18:00:00Z");
  const a = aggregate(
    [
      rec({ messageId: "t", requestId: "1", model: "claude-opus-4-8", usage: u(1e6, 0, 0, 0), timestamp: "2026-06-20T17:30:00Z" }), // today + 5h
      rec({ messageId: "o", requestId: "2", model: "claude-opus-4-8", usage: u(1e6, 0, 0, 0), timestamp: "2026-06-10T10:00:00Z" }), // older: all-time only
    ],
    { now, cost: costOfUsage },
  );
  assert.equal(a.cost.total, 10, "both records");
  assert.equal(a.cost.today, 5, "only the recent one");
  assert.equal(a.cost.rolling5h, 5);
});
