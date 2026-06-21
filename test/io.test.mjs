// Integration tests for the I/O shell (src/token-tab.mjs).
//
// The pure parser is pinned in core.test.mjs; this file pins the SHELL contract
// that backs the trust pitch: it reads only metadata, tolerates malformed lines,
// never crashes on a missing dir, and carries no prompt/response text into output.
//
// Runs the real CLI as a subprocess against a throwaway fixture dir. Fixtures use
// synthetic values only — no real prompt/response text.

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const run = promisify(execFile);
const CLI = join(dirname(fileURLToPath(import.meta.url)), "..", "src", "token-tab.mjs");

const SECRET = "NEVER-LEAK-THIS-PROMPT";
// user line (content present — must be ignored), a streaming pair sharing an id
// (output grows: keep-last), a malformed line, and a bedrock-surface line.
const FIXTURE = [
  `{"type":"user","message":{"content":"${SECRET}"},"timestamp":"2026-06-20T10:00:00Z"}`,
  `{"type":"assistant","requestId":"r1","timestamp":"2026-06-20T10:00:01Z","message":{"id":"m1","model":"claude-opus-4-8","content":"${SECRET}","usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":2}}}`,
  `{"type":"assistant","requestId":"r1","timestamp":"2026-06-20T10:00:02Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":99}}}`,
  `{ this is not valid json`,
  `{"type":"assistant","requestId":"r2","timestamp":"2026-06-20T10:00:03Z","message":{"id":"m2","model":"us.anthropic.claude-3-5-sonnet-20241022-v2:0","usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}`,
].join("\n");

function makeFixtureDir() {
  const dir = mkdtempSync(join(tmpdir(), "tokentab-io-"));
  writeFileSync(join(dir, "session.jsonl"), FIXTURE + "\n");
  return dir;
}

async function cli(args, logDir) {
  const env = { ...process.env, TOKENTAB_LOG_DIR: logDir };
  const { stdout } = await run("node", [CLI, ...args], { env });
  return stdout;
}

test("--json: keep-last dedup, surface routing, malformed lines tolerated", async () => {
  const dir = makeFixtureDir();
  try {
    const out = JSON.parse(await cli(["--json"], dir));
    assert.equal(out.total, 169, "159 (m1 keep-last final) + 10 (m2)");
    assert.equal(out.dedup.counted, 2);
    assert.equal(out.dedup.duplicatesDropped, 1, "streaming partial dropped");
    assert.equal(out.dedup.collisionsDifferingTotals, 1, "output grew across the pair");
    assert.equal(out.bySurface.subscription, 159);
    assert.equal(out.bySurface.bedrock, 10);
    assert.equal(out.parseErrors, 1, "the one malformed line is tolerated, not fatal");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("trust boundary: no prompt/response content reaches output", async () => {
  const dir = makeFixtureDir();
  try {
    const out = await cli(["--json"], dir);
    assert.ok(!out.includes(SECRET), "content must never appear in the aggregate output");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("missing log dir: graceful message, exit 0 (never crashes the menu bar)", async () => {
  const out = await cli(["--swiftbar"], join(tmpdir(), "tokentab-does-not-exist-xyz"));
  assert.match(out, /No logs found/);
});

test("--swiftbar: subscription headline is the usage window; tokens stay in the dropdown", async () => {
  const dir = makeFixtureDir(); // fixture is subscription-dominant (claude-opus-4-8)
  try {
    const out = await cli(["--swiftbar"], dir);
    // Headline is a menu-bar glyph: ◔ (active window / %) or ◧ (token fallback when idle).
    // Fixture dates are fixed, so whether the window is "active" depends on wall-clock;
    // the deterministic window behavior is pinned in core.test.mjs with an injected now.
    assert.match(out.split("\n")[0], /^[◔◧] /, "first line is the menu-bar headline");
    assert.match(out, /5h window:/, "window detail shown in the dropdown");
    assert.match(out, /Today: .* tokens/, "tokens still visible in the dropdown");
    assert.match(out, /Local only · No network/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
