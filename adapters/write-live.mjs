// Token Tab — live-usage cache WRITER (opt-in, networked, fenced OUTSIDE src/).
//
// This is the bridge that lets the sandboxed menu-bar app show the real server-side %
// WITHOUT the app itself ever touching the network. The app cannot run `claude` (no
// network entitlement — enforced), so instead THIS process — separate, user-launched —
// does the `claude -p "/usage"` call (via the existing adapter), parses it, and writes the
// percentages to a small JSON file the app then reads as plain data.
//
// The network + keychain access lives entirely here, in something you opted into and
// scheduled yourself. Run it on a timer to keep the app's live numbers fresh:
//
//   # one-off
//   node adapters/write-live.mjs
//   # every 2 minutes via launchd / cron / SwiftBar wrapper
//
// Writes to `<logDir>/.token-tab-live.json` (logDir = the same dir token-tab.mjs reads),
// which is inside the folder the app is already granted — so no extra permission, and both
// log walkers ignore it (hidden + not *.jsonl). Atomic write so the app never sees a
// half-written file. Fails closed: if the live read returns null, nothing is written.

import { writeFileSync, renameSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { homedir } from "node:os";
import { readLiveUsage } from "./claude-live.mjs";

const SCHEMA = 1;

/// Mirror resolveLogDir() in src/token-tab.mjs so the cache lands where the app reads.
export function liveCachePath(env = process.env) {
  const file = ".token-tab-live.json";
  if (env.TOKENTAB_LIVE_CACHE) return env.TOKENTAB_LIVE_CACHE; // explicit override
  if (env.TOKENTAB_LOG_DIR) return join(env.TOKENTAB_LOG_DIR, file);
  if (env.CLAUDE_CONFIG_DIR) return join(env.CLAUDE_CONFIG_DIR, "projects", file);
  return join(homedir(), ".claude", "projects", file);
}

/// PURE: shape a parsed live reading into the on-disk JSON (or null if there's nothing to
/// write). Kept separate from I/O so it's unit-testable without spawning `claude`. Percent
/// fields are normalized to `null` (not undefined) so the JSON is stable and explicit.
export function serializeLive(reading, capturedAtIso) {
  if (!reading || (reading.sessionPct == null && reading.weeklyPct == null)) return null;
  return JSON.stringify(
    {
      schema: SCHEMA,
      source: reading.source || "claude /usage",
      capturedAt: capturedAtIso,
      sessionPct: reading.sessionPct ?? null,
      sessionResetText: reading.sessionResetText ?? null,
      weeklyPct: reading.weeklyPct ?? null,
      weeklyResetText: reading.weeklyResetText ?? null,
      weeklyByModel: reading.weeklyByModel || {},
    },
    null,
    2,
  );
}

/// Read live usage and atomically write the cache. Never throws; returns a small status.
export async function writeLiveCache({ path = liveCachePath(), now = new Date() } = {}) {
  const reading = await readLiveUsage();
  const json = serializeLive(reading, now.toISOString());
  if (!json) return { ok: false, reason: "live unavailable — wrote nothing" };
  try {
    mkdirSync(dirname(path), { recursive: true });
    const tmp = `${path}.tmp`;
    writeFileSync(tmp, json, { mode: 0o600 });
    renameSync(tmp, path); // atomic swap — the app never reads a torn file
    return { ok: true, path };
  } catch (e) {
    return { ok: false, reason: `write failed: ${e.message}` };
  }
}

// CLI entry: `node adapters/write-live.mjs`. Status goes to stderr (never stdout), so the
// command is quiet on success and composes cleanly inside a SwiftBar/cron wrapper.
if (import.meta.url === `file://${process.argv[1]}`) {
  writeLiveCache().then((r) => {
    if (r.ok) {
      console.error(`[token-tab] wrote ${r.path}`);
    } else {
      console.error(`[token-tab] ${r.reason}`);
      process.exit(1);
    }
  });
}
