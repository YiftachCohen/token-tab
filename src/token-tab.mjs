#!/usr/bin/env node
// Token Tab — I/O shell (Approach C validation probe / SwiftBar plugin).
//
// Walks the Claude Code log dir, streams each JSONL file line-by-line, feeds the
// pure core, and prints your tab. Zero dependencies, no build step: what you read
// is exactly what runs. Reads only token-usage metadata, never your prompts/code,
// and makes no network calls.
//
// Usage:
//   node src/token-tab.mjs            human report (default)
//   node src/token-tab.mjs --json     machine-readable aggregate (for reconciliation)
//   node src/token-tab.mjs --swiftbar SwiftBar menu-bar format
//
// Log dir resolution: $TOKENTAB_LOG_DIR  >  $CLAUDE_CONFIG_DIR/projects  >  ~/.claude/projects

import { createReadStream, readdirSync, statSync, existsSync, readFileSync } from "node:fs";
import { createInterface } from "node:readline";
import { join } from "node:path";
import { homedir } from "node:os";
import { aggregate, recordFromLine, classifySurface } from "./core.mjs";
import { costOfUsage } from "./pricing.mjs";

function resolveLogDir() {
  if (process.env.TOKENTAB_LOG_DIR) return process.env.TOKENTAB_LOG_DIR;
  if (process.env.CLAUDE_CONFIG_DIR) return join(process.env.CLAUDE_CONFIG_DIR, "projects");
  return join(homedir(), ".claude", "projects");
}

// Load machine-local settings (e.g. TOKENTAB_WINDOW_CAP) from a KEY=VALUE file kept
// OUTSIDE the repo, so your plan cap never gets committed. Real env vars win. Only
// TOKENTAB_* keys are honored. This only reads a local file — no network, no secrets.
function loadLocalConfig() {
  const candidates = [
    process.env.TOKENTAB_CONFIG,
    join(homedir(), ".config", "token-tab", "env"),
    join(homedir(), ".token-tab.env"),
  ].filter(Boolean);
  for (const path of candidates) {
    let txt;
    try {
      txt = readFileSync(path, "utf8");
    } catch {
      continue;
    }
    for (const line of txt.split("\n")) {
      const m = line.match(/^\s*(TOKENTAB_[A-Z0-9_]+|CLAUDE_CODE_USE_BEDROCK)\s*=\s*(.*?)\s*$/);
      if (m && !(m[1] in process.env)) process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
    }
  }
}

function findJsonl(dir) {
  const out = [];
  const walk = (d) => {
    let entries;
    try {
      entries = readdirSync(d, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const p = join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.isFile() && e.name.endsWith(".jsonl")) out.push(p);
    }
  };
  walk(dir);
  // Deterministic order so first-seen dedup is reproducible: oldest mtime first.
  // Tolerate a file vanishing between the walk and the stat — Claude Code rotates
  // logs under us, and a hard crash here would just blank the menu bar.
  return out
    .map((p) => {
      try {
        return { p, mtime: statSync(p).mtimeMs };
      } catch {
        return null;
      }
    })
    .filter(Boolean)
    .sort((a, b) => a.mtime - b.mtime || (a.p < b.p ? -1 : 1))
    .map((x) => x.p);
}

async function readRecords(files) {
  const records = [];
  const parseErrors = []; // {path, line} only — never the content of the bad line
  for (const path of files) {
    let lineNo = 0;
    try {
      const rl = createInterface({ input: createReadStream(path), crlfDelay: Infinity });
      for await (const line of rl) {
        lineNo++;
        if (!line.trim()) continue;
        let obj;
        try {
          obj = JSON.parse(line);
        } catch {
          parseErrors.push({ path, line: lineNo }); // tolerate malformed (live-write) lines
          continue;
        }
        const rec = recordFromLine(obj);
        if (rec) records.push(rec);
      }
    } catch {
      // File vanished or became unreadable mid-read — skip the rest of it and
      // keep going so one rotated log doesn't abort the whole report.
      parseErrors.push({ path, line: lineNo });
    }
  }
  return { records, parseErrors };
}

function abbrev(n) {
  if (n < 1000) return String(n);
  if (n < 1e6) return (n / 1e3).toFixed(n < 1e4 ? 1 : 0) + "K";
  if (n < 1e9) return (n / 1e6).toFixed(n < 1e7 ? 1 : 0) + "M";
  return (n / 1e9).toFixed(2) + "B";
}

function fmtDur(ms) {
  if (ms == null || ms < 0) return "—";
  const mins = Math.round(ms / 60000);
  const h = Math.floor(mins / 60);
  return h > 0 ? `${h}h${String(mins % 60).padStart(2, "0")}m` : `${mins}m`;
}

// Dollars: cents under $1k, whole dollars above (a tab, not an invoice). A nonzero
// amount that rounds below a cent shows "<$0.01" so tiny spend never reads as free.
function fmtUsd(n) {
  if (!n || n < 0) return "$0.00";
  if (n < 0.01) return "<$0.01";
  if (n >= 1000) return "$" + Math.round(n).toLocaleString();
  return "$" + n.toFixed(2);
}

function dominantSurface(bySurface) {
  let best = null,
    bestN = -1;
  for (const [s, n] of Object.entries(bySurface)) {
    if (s !== "untracked" && n > bestN) {
      best = s;
      bestN = n;
    }
  }
  return best || "untracked";
}

// Opt-in live usage is OFF unless TOKENTAB_LIVE is truthy. Forgiving on value so
// `TOKENTAB_LIVE=true` (etc.) doesn't silently no-op; `=1` is the canonical form.
function isLiveEnabled(v) {
  return typeof v === "string" && /^(1|true|yes|on)$/i.test(v.trim());
}

// Force the displayed surface, mirroring the native app's Config.swift:
//   TOKENTAB_MODE wins (bedrock | subscription/max/pro/sub | payg/pay-per-token/api/untracked),
//   else a truthy CLAUDE_CODE_USE_BEDROCK forces bedrock, else null (auto-detect).
// Needed because Claude Code on Bedrock logs bare claude-* ids that classify as
// subscription — the logs alone can't reveal Bedrock.
function resolveSurfaceOverride(env) {
  const mode = (env.TOKENTAB_MODE || "").trim().toLowerCase();
  switch (mode) {
    case "bedrock":
      return "bedrock";
    case "subscription":
    case "max":
    case "pro":
    case "sub":
      return "subscription";
    case "payg":
    case "pay-per-token":
    case "paypertoken":
    case "api":
    case "untracked":
      return "untracked";
  }
  const bd = (env.CLAUDE_CODE_USE_BEDROCK || "").trim().toLowerCase();
  if (bd === "1" || bd === "true" || bd === "yes" || bd === "on") return "bedrock";
  return null;
}

async function main() {
  loadLocalConfig();
  const mode = process.argv.includes("--json")
    ? "json"
    : process.argv.includes("--swiftbar")
      ? "swiftbar"
      : "report";
  const dir = resolveLogDir();

  if (!existsSync(dir)) {
    if (mode === "swiftbar") {
      console.log("Token Tab —");
      console.log("---");
      console.log(`No logs found at ${dir} | color=gray`);
      console.log("Open Claude Code once, then refresh. | color=gray");
    } else {
      console.log(`No Claude Code logs found at ${dir}`);
      console.log("Set $TOKENTAB_LOG_DIR if your logs live elsewhere.");
    }
    process.exit(0);
  }

  const files = findJsonl(dir);
  const { records, parseErrors } = await readRecords(files);
  const cap = Number(process.env.TOKENTAB_WINDOW_CAP);
  // Dollars are local-only arithmetic on a bundled price table — no network, no key —
  // so the estimate is on by default (unlike the live server-%, which is opt-in).
  const agg = aggregate(records, {
    cap: Number.isFinite(cap) && cap > 0 ? cap : undefined,
    cost: costOfUsage,
  });

  // Opt-in live usage. Computed ONCE, before any render branch, and only when
  // enabled — the live adapter (the sole subprocess user, fenced under adapters/,
  // outside the audited core) is dynamically imported so the default path never
  // loads it. Fails closed to null: a missing/broken adapter never breaks the report.
  const liveEnabled = isLiveEnabled(process.env.TOKENTAB_LIVE);
  let live = null;
  if (liveEnabled) {
    try {
      const { readLiveUsage } = await import("../adapters/claude-live.mjs");
      live = await readLiveUsage();
    } catch {
      live = null;
    }
  }

  if (mode === "json") {
    // Default (flag unset) output stays byte-for-byte identical: `live` is only
    // appended when present, never as `live: null`, and `window` is untouched.
    const out = { ...agg, files: files.length, parseErrors: parseErrors.length };
    if (live) out.live = live;
    console.log(JSON.stringify(out, null, 2));
    return;
  }

  const surfaceOverride = resolveSurfaceOverride(process.env);
  const surface = surfaceOverride ?? dominantSurface(agg.bySurface);
  const w = agg.window;

  if (mode === "swiftbar") {
    // Local default: the headline is tokens (today). The 5h window — exact reset
    // countdown, plus a % only if you've set a cap — lives in the dropdown. All local,
    // no network. (A live server-% is a future opt-in that would phone home.)
    console.log(`◧ ${abbrev(agg.today)}`);
    console.log("---");
    if (surface === "subscription") {
      if (live) {
        // Live server numbers are authoritative, so they headline; the local
        // estimate is demoted to one gray line so two competing "5h window"
        // percentages never sit side by side.
        console.log(`5h window: ${live.sessionPct}% used · live (claude /usage)`);
        if (live.sessionResetText) console.log(`Resets ${live.sessionResetText} | color=gray`);
        if (live.weeklyPct != null) console.log(`This week: ${live.weeklyPct}% used · live`);
        for (const [m, p] of Object.entries(live.weeklyByModel || {}))
          console.log(`This week (${m}): ${p}% used · live | color=gray`);
        console.log(`local estimate: ${w.tokens.toLocaleString()} tokens${w.pct != null ? ` · ${w.pct}%` : ""} | color=gray`);
        console.log("---");
      } else {
        console.log(`5h window: ${w.tokens.toLocaleString()} tokens${w.pct != null ? ` · ${w.pct}%` : ""}`);
        console.log(`${w.active ? `Resets in ${fmtDur(w.msToReset)}` : "Window idle"}${w.pct != null ? " · cap from config" : ""} | color=gray`);
        if (w.pct == null) console.log("For a %, set TOKENTAB_WINDOW_CAP to your plan cap (from Claude /usage) | color=gray");
        // Flag set but the live read failed (e.g. claude not resolvable, parse
        // miss): say so instead of silently looking like live was never requested.
        if (liveEnabled) console.log("live unavailable — using local estimate | color=gray");
        console.log("---");
      }
    }
    console.log(`Today: ${agg.today.toLocaleString()} tokens`);
    console.log(`This week: ${agg.thisWeek.toLocaleString()}`);
    console.log(`Last 5h: ${agg.rolling5h.toLocaleString()}`);
    if (agg.cost) {
      console.log(
        `Est. cost: ${fmtUsd(agg.cost.today)} today · ${fmtUsd(agg.cost.thisWeek)} week · ${fmtUsd(agg.cost.total)} all | color=gray`,
      );
      if (agg.cost.unpriced.tokens > 0)
        console.log(`  (${abbrev(agg.cost.unpriced.tokens)} tokens unpriced) | color=gray`);
    }
    console.log("---");
    for (const [s, n] of Object.entries(agg.bySurface)) console.log(`${s}: ${n.toLocaleString()}`);
    console.log("---");
    console.log("Local only · No network · ~/.claude/projects read-only | color=gray");
    return;
  }

  // human report
  const line = (l) => console.log(l);
  line("");
  line("  Token Tab " + "─".repeat(40));
  line(`  Today:     ${abbrev(agg.today).padStart(8)}   (${agg.today.toLocaleString()} tokens)`);
  line(`  This week: ${abbrev(agg.thisWeek).padStart(8)}   (${agg.thisWeek.toLocaleString()})`);
  line(`  Last 5h:   ${abbrev(agg.rolling5h).padStart(8)}   (${agg.rolling5h.toLocaleString()})`);
  line(`  All time:  ${abbrev(agg.total).padStart(8)}   (${agg.total.toLocaleString()})`);
  line("");
  line(
    `  5h window: ${abbrev(w.tokens).padStart(8)}   ${w.pct != null ? `${w.pct}% of cap (${w.capSource})` : "set TOKENTAB_WINDOW_CAP for %"}` +
      `   ${w.active ? "resets in " + fmtDur(w.msToReset) : "(idle)"}`,
  );
  line("");
  if (live) {
    line("  live · claude /usage " + "─".repeat(29));
    line(`    session: ${live.sessionPct}% used${live.sessionResetText ? `   resets ${live.sessionResetText}` : ""}`);
    if (live.weeklyPct != null)
      line(`    week:    ${live.weeklyPct}% used${live.weeklyResetText ? `   resets ${live.weeklyResetText}` : ""}`);
    for (const [m, p] of Object.entries(live.weeklyByModel || {})) line(`    week (${m}): ${p}% used`);
    line("");
  } else if (liveEnabled) {
    line("  live unavailable — using local estimate (set TOKENTAB_LIVE_DEBUG=1 for the reason)");
    line("");
  }
  if (agg.cost) {
    line("  Cost estimate " + "─".repeat(38));
    line(
      `    today: ${fmtUsd(agg.cost.today).padStart(9)}   this week: ${fmtUsd(agg.cost.thisWeek).padStart(9)}   all time: ${fmtUsd(agg.cost.total).padStart(9)}`,
    );
    const priced = Object.entries(agg.cost.byModel).sort((a, b) => b[1] - a[1]);
    if (priced.length) {
      line("    by model:");
      for (const [m, d] of priced.slice(0, 8)) line(`      ${m.padEnd(28)} ${fmtUsd(d).padStart(9)}`);
    }
    if (agg.cost.unpriced.tokens > 0)
      line(
        `    unpriced: ${agg.cost.unpriced.requests} requests / ${abbrev(agg.cost.unpriced.tokens)} tokens (no rate for: ${agg.cost.unpriced.models.join(", ")})`,
      );
    line("    estimate from a bundled price table — a tab, not an invoice.");
    line("");
  }
  line(`  Surface: ${surface} (${surfaceOverride ? "mode override" : "dominant"})`);
  for (const [s, n] of Object.entries(agg.bySurface).sort((a, b) => b[1] - a[1]))
    line(`    ${s.padEnd(13)} ${abbrev(n).padStart(8)}`);
  line("");
  line("  By model:");
  for (const [m, n] of Object.entries(agg.byModel).sort((a, b) => b[1] - a[1]).slice(0, 8))
    line(`    ${m.padEnd(28)} ${abbrev(n).padStart(8)}`);
  line("");
  line("  By token class:");
  line(`    input ${abbrev(agg.byClass.input)}  ·  cache-create ${abbrev(agg.byClass.cacheCreate)}  ·  cache-read ${abbrev(agg.byClass.cacheRead)}  ·  output ${abbrev(agg.byClass.output)}`);
  line("");
  line("  Parse health " + "─".repeat(38));
  line(`    files:                 ${files.length}`);
  line(`    usage records counted: ${agg.dedup.counted.toLocaleString()}`);
  line(`    duplicates dropped:    ${agg.dedup.duplicatesDropped.toLocaleString()}`);
  line(`    keep-last revisions (normal for streaming): ${agg.dedup.collisionsDifferingTotals}`);
  line(`    approximate (missing id): ${agg.approximate}`);
  line(`    untracked: ${agg.untracked.requests} requests / ${abbrev(agg.untracked.tokens)} tokens`);
  line(`    malformed lines skipped: ${parseErrors.length}`);
  line("");
}

main().catch((e) => {
  console.error("token-tab error:", e.message);
  process.exit(1);
});
