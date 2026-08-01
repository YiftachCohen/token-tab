// Codex ingestion reader tests (Phase 3).
//
// These pin the delta/reset/duplicate arithmetic that .context/codex-support-design.md §2
// specifies — the correctness-critical piece. They assert on the emitted UsageRecord
// arrays DIRECTLY (this is the reader, not the aggregate: no parity here).
//
// Fixtures are synthetic Codex event sequences (no real prompt/response text) under
// test/fixtures/codex-ingest/. Each holds { lines | rawLines, expected, malformed, rateLimits }.
// Run: `node --test`

import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync, mkdtempSync, mkdirSync, writeFileSync, rmSync, utimesSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import {
  recordsFromCodexLines,
  findCodexJsonl,
  resolveCodexRoot,
  readCodexUsage,
} from "../src/codex.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const fixDir = join(here, "fixtures", "codex-ingest");

// A fixture's `lines` are event objects (re-serialized so we exercise real
// JSON.parse); `rawLines` are already strings (used to inject malformed input).
function fixtureLines(fx) {
  if (fx.rawLines) return fx.rawLines;
  return fx.lines.map((o) => JSON.stringify(o));
}

// --- fixture-driven fold tests ---------------------------------------------
for (const name of readdirSync(fixDir).filter((f) => f.endsWith(".json"))) {
  const fx = JSON.parse(readFileSync(join(fixDir, name), "utf8"));
  test(`fixture: ${name} — ${fx.desc}`, () => {
    const out = recordsFromCodexLines(fixtureLines(fx), { fileName: fx.fileName });
    assert.deepEqual(out.records, fx.expected, "emitted records mismatch");
    assert.equal(out.malformed, fx.malformed, "malformed count mismatch");
    assert.deepEqual(out.rateLimits, fx.rateLimits, "rate_limits snapshot mismatch");
  });
}

// --- targeted invariants on top of the fixtures ----------------------------

test("reset segments: reader total == sum of segment totals (98614 + 13344)", () => {
  const fx = JSON.parse(readFileSync(join(fixDir, "mid-file-reset.json"), "utf8"));
  const out = recordsFromCodexLines(fixtureLines(fx), { fileName: fx.fileName });
  const sum = out.records.reduce(
    (n, r) =>
      n +
      r.usage.input_tokens +
      r.usage.cache_read_input_tokens +
      r.usage.cache_creation_input_tokens +
      r.usage.output_tokens,
    0,
  );
  assert.equal(sum, 98614 + 13344);
});

test("no-turn-context event is flagged <codex-unknown> (marks aggregate approximate)", () => {
  const fx = JSON.parse(readFileSync(join(fixDir, "before-turn-context.json"), "utf8"));
  const out = recordsFromCodexLines(fixtureLines(fx), { fileName: fx.fileName });
  assert.equal(out.records[0].model, "<codex-unknown>");
  assert.equal(out.records[1].model, "gpt-5.4");
});

test("cache_creation is always 0 (no Codex analog); cacheRead = cached delta", () => {
  const fx = JSON.parse(readFileSync(join(fixDir, "cumulative-growth.json"), "utf8"));
  const out = recordsFromCodexLines(fixtureLines(fx), { fileName: fx.fileName });
  for (const r of out.records) assert.equal(r.usage.cache_creation_input_tokens, 0);
});

test("total_tokens is never used for arithmetic (per-class reset only)", () => {
  // total_tokens grows monotonically here (240 -> 350) even though a class
  // (output) resets. If the fold gated on total_tokens it would MISS the reset
  // and undercount. Independent per-class detection catches it.
  const lines = [
    { type: "session_meta", timestamp: "2026-06-20T20:00:00.000Z", payload: { id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" } },
    { type: "turn_context", payload: { model: "gpt-5.4" } },
    { type: "event_msg", timestamp: "2026-06-20T20:01:00.000Z", payload: { type: "token_count", info: { total_token_usage: { input_tokens: 40, cached_input_tokens: 0, output_tokens: 200, total_tokens: 240 } }, rate_limits: null } },
    { type: "event_msg", timestamp: "2026-06-20T20:02:00.000Z", payload: { type: "token_count", info: { total_token_usage: { input_tokens: 300, cached_input_tokens: 0, output_tokens: 50, total_tokens: 350 } }, rate_limits: null } },
  ].map((o) => JSON.stringify(o));
  const out = recordsFromCodexLines(lines, { fileName: "x.jsonl" });
  // second event: input 40->300 (d=260), output 200->50 (reset, d=50).
  assert.equal(out.records[1].usage.input_tokens, 260);
  assert.equal(out.records[1].usage.output_tokens, 50);
});

test("malformed line count is exact and does not abort the fold", () => {
  const fx = JSON.parse(readFileSync(join(fixDir, "malformed-trailing.json"), "utf8"));
  const out = recordsFromCodexLines(fixtureLines(fx), { fileName: fx.fileName });
  assert.equal(out.malformed, 1);
  assert.equal(out.records.length, 1);
});

test("blank lines are ignored (not counted as malformed)", () => {
  const out = recordsFromCodexLines(["", "   ", ""], { fileName: "x.jsonl" });
  assert.equal(out.malformed, 0);
  assert.equal(out.records.length, 0);
});

// TRUST BOUNDARY: response_item lines are never DECODED — not merely "decoded but
// not surfaced". That distinction is observable: the second line below is a
// deliberately TRUNCATED response_item (unbalanced braces). If it ever reached
// JSON.parse it would throw and land in `malformed`. malformed === 0 is therefore
// direct proof that the line was dropped as a raw string, its content never parsed
// and never allocated. The final assertions still pin the second layer — that a
// session_meta's `instructions`/`cwd` can't surface even from a decoded line.
test("no-content: response_item lines are skipped before JSON.parse; instructions never read", () => {
  const lines = [
    JSON.stringify({ type: "session_meta", timestamp: "2026-06-20T21:00:00.000Z", payload: { id: "11111111-2222-3333-4444-555555555555", instructions: "SECRET PROMPT TEXT", cwd: "/secret/path" } }),
    `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"text","text":"SECRET USER MESSAGE`,
    JSON.stringify({ type: "response_item", payload: { type: "reasoning", content: "SECRET REASONING" } }),
    JSON.stringify({ type: "turn_context", payload: { model: "gpt-5.4", cwd: "/secret/path" } }),
    JSON.stringify({ type: "event_msg", timestamp: "2026-06-20T21:01:00.000Z", payload: { type: "token_count", info: { total_token_usage: { input_tokens: 10, cached_input_tokens: 0, output_tokens: 5, total_tokens: 15 } }, rate_limits: null } }),
  ];
  const out = recordsFromCodexLines(lines, { fileName: "x.jsonl" });
  assert.equal(out.records.length, 1);
  assert.equal(
    out.malformed,
    0,
    "an unparseable response_item must be skipped BEFORE JSON.parse, not parsed and rejected",
  );
  const blob = JSON.stringify(out);
  assert.ok(!blob.includes("SECRET"), "no content field must leak into records");
  assert.ok(!blob.includes("/secret/path"), "no cwd must leak");
});

// --- config resolution ------------------------------------------------------

test("resolveCodexRoot precedence: TOKENTAB_CODEX_LOG_DIR > CODEX_HOME > ~/.codex", () => {
  assert.equal(
    resolveCodexRoot({ TOKENTAB_CODEX_LOG_DIR: "/a", CODEX_HOME: "/b" }),
    "/a",
  );
  assert.equal(resolveCodexRoot({ CODEX_HOME: "/b" }), "/b");
  assert.ok(resolveCodexRoot({}).endsWith("/.codex"));
});

// --- filesystem-level: walker order + cross-file rate_limits latest-wins ----

test("findCodexJsonl walks sessions/** + archived_sessions/*, deterministic order", () => {
  const root = mkdtempSync(join(tmpdir(), "codex-walk-"));
  try {
    mkdirSync(join(root, "sessions", "2026", "06", "20"), { recursive: true });
    mkdirSync(join(root, "archived_sessions"), { recursive: true });
    const a = join(root, "sessions", "2026", "06", "20", "rollout-a.jsonl");
    const b = join(root, "archived_sessions", "rollout-b.jsonl");
    writeFileSync(a, "{}\n");
    writeFileSync(b, "{}\n");
    // Make `b` older so mtime order puts it first.
    utimesSync(b, new Date(1000), new Date(1000));
    utimesSync(a, new Date(2000), new Date(2000));
    const files = findCodexJsonl(root);
    assert.deepEqual(files, [b, a], "oldest mtime first");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("readCodexUsage: rate_limits latest-wins ACROSS files (by asOf)", async () => {
  const root = mkdtempSync(join(tmpdir(), "codex-rl-"));
  try {
    const dir = join(root, "sessions", "2026", "06", "20");
    mkdirSync(dir, { recursive: true });
    const older = {
      type: "event_msg",
      timestamp: "2026-06-20T10:00:00.000Z",
      payload: {
        type: "token_count",
        info: { total_token_usage: { input_tokens: 1, cached_input_tokens: 0, output_tokens: 1, total_tokens: 2 } },
        rate_limits: { primary: { used_percent: 5, window_minutes: 300, resets_at: 1 }, plan_type: "plus" },
      },
    };
    const newer = {
      type: "event_msg",
      timestamp: "2026-06-20T12:00:00.000Z",
      payload: {
        type: "token_count",
        info: { total_token_usage: { input_tokens: 1, cached_input_tokens: 0, output_tokens: 1, total_tokens: 2 } },
        rate_limits: { primary: { used_percent: 88, window_minutes: 300, resets_at: 2 }, plan_type: "plus" },
      },
    };
    // Write the NEWER-content file with an OLDER mtime so ordering can't be what
    // picks the snapshot — only asOf should.
    const fNewer = join(dir, "rollout-2026-06-20T00-00-00-00000000-0000-0000-0000-000000000001.jsonl");
    const fOlder = join(dir, "rollout-2026-06-20T00-00-00-00000000-0000-0000-0000-000000000002.jsonl");
    writeFileSync(fNewer, JSON.stringify(newer) + "\n");
    writeFileSync(fOlder, JSON.stringify(older) + "\n");
    utimesSync(fNewer, new Date(1000), new Date(1000)); // walked first
    utimesSync(fOlder, new Date(2000), new Date(2000)); // walked second
    const out = await readCodexUsage(root);
    assert.equal(out.codexRateLimits.primary.used_percent, 88, "later asOf wins regardless of walk order");
    assert.equal(out.codexRateLimits.asOf, "2026-06-20T12:00:00.000Z");
    assert.equal(out.records.length, 2);
    assert.equal(out.malformed, 0);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
