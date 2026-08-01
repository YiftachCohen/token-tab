#!/usr/bin/env node
// Codex reader vs ccusage cross-check (manual, NOT part of `node --test`).
//
// Compares per-day Codex token totals from our reader against `ccusage --json`
// (Codex scope). Tokens only — cost is never compared. ccusage is optional: if
// it isn't installed/usable, this prints a skip message and exits 0 (never a
// failure) so it's safe to wire into CI as a best-effort probe.
//
// Usage: node scripts/codex-crosscheck.mjs
// Env:   TOKENTAB_CODEX_LOG_DIR / CODEX_HOME override the Codex root.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { readCodexUsage, resolveCodexRoot, findCodexJsonl } from "../src/codex.mjs";

function localDayKey(iso) {
  const d = new Date(iso);
  if (isNaN(d)) return null;
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function sumU(u) {
  return (
    u.input_tokens + u.cache_read_input_tokens + u.cache_creation_input_tokens + u.output_tokens
  );
}

async function ours(root) {
  const { records } = await readCodexUsage(root);
  const byDay = {};
  for (const r of records) {
    const k = r.timestamp ? localDayKey(r.timestamp) : null;
    if (!k) continue;
    byDay[k] = (byDay[k] || 0) + sumU(r.usage);
  }
  return byDay;
}

// ccusage's Codex daily JSON shape isn't pinned across versions, so probe
// defensively and bail (skip, not fail) on anything unexpected.
function ccusageByDay() {
  let raw;
  try {
    raw = execFileSync("ccusage", ["codex", "daily", "--json"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
  } catch {
    return null; // not installed / different subcommand — skip
  }
  let data;
  try {
    data = JSON.parse(raw);
  } catch {
    return null;
  }
  const rows = Array.isArray(data) ? data : data?.daily || data?.data;
  if (!Array.isArray(rows)) return null;
  const byDay = {};
  for (const row of rows) {
    const date = row.date || row.day;
    if (!date) continue;
    const tok =
      row.totalTokens ??
      (row.inputTokens || 0) +
        (row.outputTokens || 0) +
        (row.cacheReadTokens || row.cacheReadInputTokens || 0) +
        (row.cacheCreationTokens || row.cacheCreationInputTokens || 0);
    byDay[date] = (byDay[date] || 0) + (Number(tok) || 0);
  }
  return byDay;
}

async function main() {
  const root = resolveCodexRoot(process.env);
  const files = findCodexJsonl(root);
  if (!files.length) {
    console.log(`No Codex logs under ${root} — nothing to cross-check.`);
    return;
  }
  const mine = await ours(root);
  const theirs = ccusageByDay();
  if (!theirs) {
    console.log("ccusage unavailable (or unrecognized output) — skipping cross-check.");
    console.log("Our per-day Codex totals:");
    for (const [d, n] of Object.entries(mine).sort()) console.log(`  ${d}  ${n.toLocaleString()}`);
    return;
  }
  const days = [...new Set([...Object.keys(mine), ...Object.keys(theirs)])].sort();
  let diffs = 0;
  console.log("day          ours          ccusage       delta");
  for (const d of days) {
    const a = mine[d] || 0;
    const b = theirs[d] || 0;
    const delta = a - b;
    if (delta !== 0) diffs++;
    console.log(
      `${d}  ${String(a).padStart(12)}  ${String(b).padStart(12)}  ${String(delta).padStart(10)}`,
    );
  }
  console.log(diffs === 0 ? "\nEXACT parity across all days." : `\n${diffs} day(s) differ (see delta).`);
}

main().catch((e) => {
  console.error("codex-crosscheck error:", e.message);
  process.exit(1);
});
