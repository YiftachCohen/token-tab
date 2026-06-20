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

import { createReadStream, readdirSync, statSync, existsSync } from "node:fs";
import { createInterface } from "node:readline";
import { join } from "node:path";
import { homedir } from "node:os";
import { aggregate, recordFromLine, classifySurface } from "./core.mjs";

function resolveLogDir() {
  if (process.env.TOKENTAB_LOG_DIR) return process.env.TOKENTAB_LOG_DIR;
  if (process.env.CLAUDE_CONFIG_DIR) return join(process.env.CLAUDE_CONFIG_DIR, "projects");
  return join(homedir(), ".claude", "projects");
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
  return out
    .map((p) => ({ p, mtime: statSync(p).mtimeMs }))
    .sort((a, b) => a.mtime - b.mtime || (a.p < b.p ? -1 : 1))
    .map((x) => x.p);
}

async function readRecords(files) {
  const records = [];
  const parseErrors = []; // {path, line} only — never the content of the bad line
  for (const path of files) {
    let lineNo = 0;
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
  }
  return { records, parseErrors };
}

function abbrev(n) {
  if (n < 1000) return String(n);
  if (n < 1e6) return (n / 1e3).toFixed(n < 1e4 ? 1 : 0) + "K";
  if (n < 1e9) return (n / 1e6).toFixed(n < 1e7 ? 1 : 0) + "M";
  return (n / 1e9).toFixed(2) + "B";
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

async function main() {
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
  const agg = aggregate(records);

  if (mode === "json") {
    console.log(JSON.stringify({ ...agg, files: files.length, parseErrors: parseErrors.length }, null, 2));
    return;
  }

  if (mode === "swiftbar") {
    console.log(`◧ ${abbrev(agg.today)}`); // headline: tokens used today
    console.log("---");
    console.log(`Today: ${agg.today.toLocaleString()} tokens`);
    console.log(`This week: ${agg.thisWeek.toLocaleString()}`);
    console.log(`Last 5h: ${agg.rolling5h.toLocaleString()}`);
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
  line(`  Surface: ${dominantSurface(agg.bySurface)} (dominant)`);
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
  line(`    key collisions w/ DIFFERING totals: ${agg.dedup.collisionsDifferingTotals}  <- the dedup-rule risk`);
  line(`    approximate (missing id): ${agg.approximate}`);
  line(`    untracked: ${agg.untracked.requests} requests / ${abbrev(agg.untracked.tokens)} tokens`);
  line(`    malformed lines skipped: ${parseErrors.length}`);
  line("");
}

main().catch((e) => {
  console.error("token-tab error:", e.message);
  process.exit(1);
});
