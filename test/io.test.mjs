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
import { mkdtempSync, writeFileSync, rmSync, mkdirSync } from "node:fs";
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

// Codex is opt-in per design (TOKENTAB_PROVIDERS default = "whose dir exists"), but
// these tests run on a real dev machine that may well have a real ~/.codex — so every
// subprocess gets a nonexistent Codex root by default, keeping these tests pinned to
// Claude-only behavior regardless of the machine they run on. Tests that want to
// exercise Codex wiring pass their own TOKENTAB_CODEX_LOG_DIR via `extraEnv`.
function isolatedEnv(logDir, extraEnv) {
  return {
    ...process.env,
    TOKENTAB_LOG_DIR: logDir,
    TOKENTAB_CODEX_LOG_DIR: join(tmpdir(), "tokentab-codex-does-not-exist-xyz"),
    ...extraEnv,
  };
}

async function cli(args, logDir, extraEnv) {
  const env = isolatedEnv(logDir, extraEnv);
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
    // Headline is the ◧ glyph + today's tokens (see swiftbar/README.md). The 5h window
    // detail lives in the dropdown, not the headline; its deterministic behavior is pinned
    // in core.test.mjs with an injected now.
    assert.match(out.split("\n")[0], /^◧ /, "first line is the ◧ token headline");
    assert.match(out, /5h window:/, "window detail shown in the dropdown");
    assert.match(out, /Today: .* tokens/, "tokens still visible in the dropdown");
    assert.match(out, /Local only · No network/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("window cap from a local config file (TOKENTAB_CONFIG) -> dropdown shows a %", async () => {
  const dir = makeFixtureDir();
  const cfg = join(tmpdir(), `tt-cfg-${process.pid}-${Math.floor(performance.now())}.env`);
  writeFileSync(cfg, "TOKENTAB_WINDOW_CAP=1000\n");
  try {
    const env = isolatedEnv(dir, { TOKENTAB_CONFIG: cfg });
    delete env.TOKENTAB_WINDOW_CAP; // prove the value comes from the file, not the env
    const { stdout } = await run("node", [CLI, "--swiftbar"], { env });
    assert.match(stdout, /5h window:.*%/, "a % appears once a cap is configured via file");
    assert.match(stdout, /cap from config/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
    rmSync(cfg, { force: true });
  }
});

test("CRLF line endings in a local config file are tolerated (window cap still applies)", async () => {
  // Pins that the JS regex's trailing `\s*$` absorbs the \r of a Windows-line-ending file —
  // the Swift parser is fixed to match this (Config.parseEnvFile splits on any newline).
  const dir = makeFixtureDir();
  const cfg = join(tmpdir(), `tt-cfg-${process.pid}-${Math.floor(performance.now())}.env`);
  writeFileSync(cfg, "TOKENTAB_WINDOW_CAP=1000\r\n");
  try {
    const env = isolatedEnv(dir, { TOKENTAB_CONFIG: cfg });
    delete env.TOKENTAB_WINDOW_CAP; // prove the value comes from the file, not the env
    const { stdout } = await run("node", [CLI, "--swiftbar"], { env });
    assert.match(stdout, /5h window:.*%/, "a % appears once a cap is configured, even with CRLF");
    assert.match(stdout, /cap from config/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
    rmSync(cfg, { force: true });
  }
});

test("TOKENTAB_MODE=bedrock suppresses the subscription 5h-window panel (swiftbar)", async () => {
  const dir = makeFixtureDir(); // fixture is subscription-dominant (claude-opus-4-8)
  try {
    const env = isolatedEnv(dir, { TOKENTAB_MODE: "bedrock" });
    const { stdout } = await run("node", [CLI, "--swiftbar"], { env });
    assert.ok(!stdout.includes("5h window:"), "no subscription window for a bedrock surface");
    assert.match(stdout, /Today: .* tokens/);
    assert.match(stdout, /Local only · No network/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("TOKENTAB_MODE=bedrock labels the report surface as a mode override", async () => {
  const dir = makeFixtureDir();
  try {
    const env = isolatedEnv(dir, { TOKENTAB_MODE: "bedrock" });
    const { stdout } = await run("node", [CLI], { env });
    assert.match(stdout, /Surface: bedrock \(mode override\)/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("CLAUDE_CODE_USE_BEDROCK=1 from the env file forces Bedrock", async () => {
  const dir = makeFixtureDir();
  const cfg = join(tmpdir(), `tt-cfg-${process.pid}-${Math.floor(performance.now())}.env`);
  writeFileSync(cfg, "CLAUDE_CODE_USE_BEDROCK=1\n");
  try {
    const env = isolatedEnv(dir, { TOKENTAB_CONFIG: cfg });
    delete env.CLAUDE_CODE_USE_BEDROCK; // prove the value comes from the file, not the env
    const { stdout } = await run("node", [CLI], { env });
    assert.match(stdout, /Surface: bedrock/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
    rmSync(cfg, { force: true });
  }
});

// --- Codex wiring (design doc §5/§6/§8 phase 5) --------------------------------

// A minimal synthetic Codex root: one session file under sessions/YYYY/MM/DD/ with a
// token_count carrying an official rate_limits snapshot, so the reader has both
// records (byModel/byProvider totals) and a snapshot (providers.codex.windows).
//
// The reset times are computed RELATIVE TO NOW rather than hardcoded, because the CLI now
// refuses to headline (or present-tense) an official window whose resetAt has passed — a
// fixed 2026 date would silently expire and turn these tests into no-ops. `resetsInHours`
// is negative for the expired case.
function makeCodexRoot({ resetsInHours = 4 } = {}) {
  const root = mkdtempSync(join(tmpdir(), "tokentab-io-codex-"));
  const day = join(root, "sessions", "2026", "06", "20");
  mkdirSync(day, { recursive: true });
  const primaryReset = new Date(Date.now() + resetsInHours * 3600_000).toISOString();
  const secondaryReset = new Date(Date.now() + (resetsInHours + 168) * 3600_000).toISOString();
  const lines = [
    `{"type":"session_meta","timestamp":"2026-06-20T12:00:00Z","payload":{"id":"019ee600-0000-7000-8000-000000000099"}}`,
    `{"type":"turn_context","payload":{"model":"gpt-5.4"}}`,
    `{"type":"event_msg","timestamp":"2026-06-20T12:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":300,"total_tokens":1300}},"rate_limits":{"primary":{"used_percent":7,"resets_at":"${primaryReset}","window_minutes":300},"secondary":{"used_percent":48,"resets_at":"${secondaryReset}","window_minutes":10080},"plan_type":"plus"}}}`,
  ].join("\n");
  writeFileSync(join(day, "rollout-2026-06-20T12-00-00-019ee600-0000-7000-8000-000000000099.jsonl"), lines + "\n");
  return { root, primaryReset };
}

test("--json: TOKENTAB_PROVIDERS default merges Codex when its dir exists, with resetAt as epoch ms", async () => {
  const dir = makeFixtureDir();
  const { root: codexRoot, primaryReset } = makeCodexRoot();
  try {
    const env = isolatedEnv(dir, { TOKENTAB_CODEX_LOG_DIR: codexRoot });
    const { stdout } = await run("node", [CLI, "--json"], { env });
    const out = JSON.parse(stdout);
    assert.ok(out.providers.codex, "providers.codex present");
    assert.equal(out.providers.codex.byModel["gpt-5.4"], 1300, "codex tokens merged in");
    assert.equal(out.providerOrder.includes("codex"), true);
    const primary = out.providers.codex.windows.primary;
    assert.equal(typeof primary.resetAt, "number", "resetAt normalized to epoch ms, not a raw ISO string");
    assert.equal(primary.resetAt, Date.parse(primaryReset));
    assert.equal(primary.usedPct, 7);
  } finally {
    rmSync(dir, { recursive: true, force: true });
    rmSync(codexRoot, { recursive: true, force: true });
  }
});

test("--json: TOKENTAB_PROVIDERS=claude disables Codex even when its dir exists", async () => {
  const dir = makeFixtureDir();
  const { root: codexRoot } = makeCodexRoot();
  try {
    const env = isolatedEnv(dir, { TOKENTAB_CODEX_LOG_DIR: codexRoot, TOKENTAB_PROVIDERS: "claude" });
    const { stdout } = await run("node", [CLI, "--json"], { env });
    const out = JSON.parse(stdout);
    assert.ok(!out.providers.codex, "codex excluded when not requested");
  } finally {
    rmSync(dir, { recursive: true, force: true });
    rmSync(codexRoot, { recursive: true, force: true });
  }
});

test("human report: Codex section shows official windows + per-model breakdown; trust line mentions ~/.codex", async () => {
  const dir = makeFixtureDir();
  const { root: codexRoot } = makeCodexRoot();
  try {
    const env = isolatedEnv(dir, { TOKENTAB_CODEX_LOG_DIR: codexRoot });
    const { stdout } = await run("node", [CLI], { env });
    assert.match(stdout, /Codex ─/, "Codex section header present");
    assert.match(stdout, /5h window: 7% used · resets \d\d:\d\d · official/);
    assert.match(stdout, /This week: 48% used · resets \d\d:\d\d · official/);
    assert.match(stdout, /gpt-5\.4/);
    assert.match(stdout, /0 network calls · reads ~\/\.claude \+ ~\/\.codex/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
    rmSync(codexRoot, { recursive: true, force: true });
  }
});

test("human report: trust line omits + ~/.codex when the Codex dir is absent", async () => {
  const dir = makeFixtureDir();
  try {
    const stdout = await cli([], dir);
    assert.match(stdout, /0 network calls · reads ~\/\.claude$/m);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("--swiftbar: Codex official % headlines with a Cdx suffix when it out-pressures Claude", async () => {
  const dir = makeFixtureDir(); // Claude fixture has no TOKENTAB_WINDOW_CAP -> no real Claude %
  const { root: codexRoot } = makeCodexRoot(); // Codex official 5h used_percent = 7
  try {
    const env = isolatedEnv(dir, { TOKENTAB_CODEX_LOG_DIR: codexRoot });
    const { stdout } = await run("node", [CLI, "--swiftbar"], { env });
    // Ranked on 7% USED, but printed as 93% LEFT — the label speaks the same "% left" as
    // the native app's menu bar (2026-07-30 DESIGN.md row). The dropdown below still
    // quotes the official reading in its native "% used" form.
    assert.match(stdout.split("\n")[0], /^◧ 93% Cdx$/, "Codex's real % headlines as % left, with the Cdx suffix");
    assert.match(stdout, /Codex —/);
    assert.match(stdout, /5h window: 7% used · resets \d\d:\d\d · official/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
    rmSync(codexRoot, { recursive: true, force: true });
  }
});

test("diagnostics: `files` counts BOTH providers, split per provider", async () => {
  const dir = makeFixtureDir();          // 1 Claude file
  const { root: codexRoot } = makeCodexRoot();  // 1 Codex file
  try {
    const env = isolatedEnv(dir, { TOKENTAB_CODEX_LOG_DIR: codexRoot });
    const out = JSON.parse((await run("node", [CLI, "--json"], { env })).stdout);
    assert.equal(out.files, 2, "every file opened is counted, not just Claude's");
    assert.deepEqual(out.filesByProvider, { claude: 1, codex: 1 });

    const report = (await run("node", [CLI], { env })).stdout;
    assert.match(report, /files:\s+2\s+\(claude 1 · codex 1\)/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
    rmSync(codexRoot, { recursive: true, force: true });
  }
});

test("diagnostics + trust line: a Codex-ONLY run never claims to have read ~/.claude", async () => {
  const dir = makeFixtureDir();
  const { root: codexRoot } = makeCodexRoot();
  try {
    // TOKENTAB_PROVIDERS=codex means the Claude dir is never opened, so neither the file
    // count nor the trust line may mention it.
    const env = isolatedEnv(dir, { TOKENTAB_CODEX_LOG_DIR: codexRoot, TOKENTAB_PROVIDERS: "codex" });
    const out = JSON.parse((await run("node", [CLI, "--json"], { env })).stdout);
    assert.equal(out.files, 1, "the Codex file is counted even with Claude disabled");
    assert.deepEqual(out.filesByProvider, { claude: 0, codex: 1 });
    assert.ok(!out.providers.claude, "no Claude records were read");

    const report = (await run("node", [CLI], { env })).stdout;
    assert.match(report, /0 network calls · reads ~\/\.codex$/m);
    assert.ok(!report.includes("reads ~/.claude"), "must not name a directory it never opened");

    const bar = (await run("node", [CLI, "--swiftbar"], { env })).stdout;
    assert.match(bar, /Local only · No network · ~\/\.codex read-only/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
    rmSync(codexRoot, { recursive: true, force: true });
  }
});

test("--swiftbar: an EXPIRED Codex window never headlines (its % belongs to a window that already reset)", async () => {
  const dir = makeFixtureDir();
  // Same 7%-used snapshot as the test above, but its recorded window reset an hour ago.
  // Codex only writes logs while it runs, so this is what a machine that stopped using
  // Codex looks like forever — the stale % must stop competing rather than win by default.
  const { root: codexRoot } = makeCodexRoot({ resetsInHours: -1 });
  try {
    const env = isolatedEnv(dir, { TOKENTAB_CODEX_LOG_DIR: codexRoot });
    const { stdout } = await run("node", [CLI, "--swiftbar"], { env });
    const headline = stdout.split("\n")[0];
    assert.ok(!headline.includes("Cdx"), `expired Codex % must not headline, got: ${headline}`);
    assert.match(headline, /^◧ \d/, "falls back to combined today-tokens");
    // The detail line still reports the number — it's real — but not in the present tense.
    assert.match(stdout, /5h window: 7% used · window reset at \d\d:\d\d · last known/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
    rmSync(codexRoot, { recursive: true, force: true });
  }
});

test("--swiftbar: falls back to combined today-tokens when neither provider has a real %", async () => {
  const dir = makeFixtureDir();
  try {
    const out = await cli(["--swiftbar"], dir);
    assert.match(out.split("\n")[0], /^◧ \d/, "falls back to today tokens, no Cdx suffix");
    assert.ok(!out.split("\n")[0].includes("Cdx"));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
