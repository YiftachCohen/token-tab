// Token Tab — opt-in live usage adapter.
//
// This is the ONLY file in the repo that imports node:child_process. It is
// deliberately fenced OUTSIDE src/ so the trust-critical core stays a clean
// sweep: `grep -RnE "child_process|spawn|execFile" src/` prints nothing.
//
// It is loaded only via a dynamic import() in src/token-tab.mjs, and only when
// TOKENTAB_LIVE is enabled. It spawns the official `claude` CLI in print mode
// (`claude -p "/usage"`), which does the keychain read and the network call;
// Token Tab only parses the printed stdout. The parser is pure and lives in
// src/live-parse.mjs.
//
// Fail closed: ANY problem (binary not found, non-zero exit, timeout, parse
// miss) resolves to null. Stores/transmits nothing. The only optional output is
// a single stderr line when TOKENTAB_LIVE_DEBUG is set.

import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { homedir, tmpdir } from "node:os";
import { parseUsageOutput } from "../src/live-parse.mjs";

// SwiftBar runs plugins with a minimal PATH (the wrapper already hardcodes the
// `node` lookup for this reason), so `claude` is usually NOT on PATH there.
// Resolve it explicitly, honoring an override, then known install locations,
// then PATH as a last resort.
function resolveClaude() {
  if (process.env.TOKENTAB_CLAUDE_BIN) return process.env.TOKENTAB_CLAUDE_BIN;
  const candidates = [
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
    join(homedir(), ".claude", "local", "claude"),
    join(homedir(), ".local", "bin", "claude"),
    join(homedir(), ".bun", "bin", "claude"),
  ];
  for (const c of candidates) {
    if (existsSync(c)) return c;
  }
  return "claude"; // last resort: PATH
}

const isDebug = (v) => typeof v === "string" && /^(1|true|yes|on)$/i.test(v.trim());

/**
 * Spawn `claude -p "/usage" --output-format json`, parse it, and return the live
 * window object — or null on any failure. Never throws.
 *
 * @param {{timeoutMs?:number}} opts
 * @returns {Promise<null | object>}
 */
export async function readLiveUsage({ timeoutMs = 5000 } = {}) {
  const bin = resolveClaude();
  const debug = isDebug(process.env.TOKENTAB_LIVE_DEBUG);
  return await new Promise((resolve) => {
    let settled = false;
    const done = (val, reason) => {
      if (settled) return; // settle exactly once (timeout vs late callback)
      settled = true;
      if (val == null && debug && reason) console.error(`[token-tab live] ${reason}`);
      resolve(val);
    };
    let child;
    try {
      child = execFile(
        bin,
        ["-p", "/usage", "--output-format", "json"],
        // Run claude in a neutral temp dir, NOT the inherited cwd. `claude -p` still
        // boots a session rooted at its working directory and indexes it; under the
        // LaunchAgent that cwd is $HOME, so it walks into ~/Desktop / ~/Documents /
        // ~/Downloads and trips macOS's TCC consent prompts (attributed to the parent
        // "node"). /usage reads the server quota, never local files, so an empty
        // tmpdir gives it nothing to scan and the prompts never fire.
        { cwd: tmpdir(), timeout: timeoutMs, killSignal: "SIGTERM", maxBuffer: 256 * 1024, windowsHide: true },
        (err, stdout) => {
          if (err) return done(null, `spawn failed: ${err.code || err.message}`);
          const parsed = parseUsageOutput(stdout);
          return done(parsed, parsed ? null : "parse miss");
        },
      );
    } catch (e) {
      return done(null, `exec threw: ${e.message}`);
    }
    // Never let `claude -p` block waiting on stdin.
    try {
      child.stdin?.end();
    } catch {
      /* ignore */
    }
  });
}
