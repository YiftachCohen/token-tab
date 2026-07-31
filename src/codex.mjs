// Token Tab — Codex ingestion reader.
//
// Codex (OpenAI CLI) writes JSONL rollout logs under ~/.codex/sessions and
// ~/.codex/archived_sessions. Unlike Claude's per-message usage, Codex logs a
// `token_count` event whose `total_token_usage` is CUMULATIVE per session — and
// (verified on the user's real logs) resets mid-file on compaction and emits
// duplicate pairs. So we can't sum; we fold deltas per token class with an
// independent reset guard per class. See .context/codex-support-design.md §2.
//
// TRUST BOUNDARY: we read each line's top-level `type` off the RAW STRING and
// drop anything outside the whitelist before it ever reaches JSON.parse — so a
// `response_item` line's prompt/response text is never decoded, never allocated,
// never in this process's heap. Lines that survive the pre-filter are then
// destructured for the whitelisted numeric/metadata fields only (content fields,
// incl. session_meta.instructions and cwd, have no code path out). The
// no-content test pins both halves.

import { createReadStream, readdirSync, statSync } from "node:fs";
import { createInterface } from "node:readline";
import { join } from "node:path";
import { homedir } from "node:os";

/** Codex root dir: $TOKENTAB_CODEX_LOG_DIR > $CODEX_HOME > ~/.codex.
 * This is the ROOT — `sessions/` and `archived_sessions/` are subdirs. */
export function resolveCodexRoot(env = process.env) {
  if (env.TOKENTAB_CODEX_LOG_DIR) return env.TOKENTAB_CODEX_LOG_DIR;
  if (env.CODEX_HOME) return env.CODEX_HOME;
  return join(homedir(), ".codex");
}

/** Walk sessions (recursive) + archived_sessions/*.jsonl under `root`.
 * Deterministic order (oldest mtime first, then path) — same convention as the
 * Claude walker in src/token-tab.mjs, so first-seen dedup is reproducible.
 * Tolerates missing subdirs and files vanishing between walk and stat. */
export function findCodexJsonl(root) {
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
  walk(join(root, "sessions"));
  walk(join(root, "archived_sessions"));
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

// uuid embedded in `rollout-<ts>-<uuid>.jsonl`. The <ts> also contains dashes,
// so anchor on the trailing 8-4-4-4-12 uuid before the extension.
const UUID_RE = /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/i;
function uuidFromFileName(fileName) {
  if (typeof fileName !== "string") return null;
  const m = fileName.match(UUID_RE);
  return m ? m[1] : null;
}

// The only three top-level `type` values we ever decode. Everything else — above
// all `response_item`, the line that actually carries your prompts, responses and
// reasoning — is dropped as an undecoded string.
const DECODED_TYPES = new Set(["session_meta", "turn_context", "event_msg"]);

// First `"type": "..."` in the raw line. Codex writes the top-level envelope keys
// (`timestamp`, `type`, `payload`) before the payload, so the first match IS the
// top-level type. If a nested field ever matched first, the worst case is that we
// decode a line we would have skipped — the `obj.type` switch below still refuses
// to read it — so this only ever fails toward the existing behavior, never toward
// surfacing content. A line with no `"type"` at all falls through to JSON.parse so
// the malformed-line count stays honest.
const TOP_TYPE_RE = /"type"\s*:\s*"([A-Za-z0-9_.-]+)"/;

/**
 * Pure per-file fold (spec §2). Takes the file's lines (strings) and returns
 * the emitted UsageRecords plus diagnostics and the file's latest rate_limits
 * snapshot.
 *
 * @param {string[]} lines raw JSONL lines (one per array element)
 * @param {{fileName?:string}} opts fileName used for the session-id fallback
 * @returns {{records:object[], malformed:number, rateLimits:object|null}}
 */
export function recordsFromCodexLines(lines, { fileName } = {}) {
  const records = [];
  let malformed = 0;
  // Per-class running baselines. total_tokens is NEVER used for arithmetic.
  const prev = { input: 0, cached: 0, output: 0 };
  let sessionId = null;
  let currentModel = null;
  let seq = 0;
  let rateLimits = null; // file's latest non-null snapshot (by event ts)
  let rateLimitsAsOf = null;

  const deltaFor = (cur, base) =>
    // shrank ⇒ reset (compaction) ⇒ the current value IS the new segment's delta
    // and becomes the new baseline; otherwise ordinary cumulative growth.
    cur >= base ? cur - base : cur;

  for (const line of lines) {
    if (typeof line !== "string" || !line.trim()) continue;
    // Content gate — BEFORE JSON.parse. A non-whitelisted type is skipped as a raw
    // string, so its content is never decoded. Not counted as malformed: it's a
    // well-formed line we deliberately don't read.
    const topType = TOP_TYPE_RE.exec(line);
    if (topType && !DECODED_TYPES.has(topType[1])) continue;
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      malformed++; // tolerate half-written / trailing lines
      continue;
    }
    if (!obj || typeof obj !== "object") {
      malformed++;
      continue;
    }
    const type = obj.type;

    if (type === "session_meta") {
      // whitelist: payload.id only (never .instructions / .cwd / etc.)
      const id = obj.payload?.id;
      if (typeof id === "string" && id) sessionId = id;
      continue;
    }

    if (type === "turn_context") {
      // whitelist: payload.model only
      const model = obj.payload?.model;
      if (typeof model === "string" && model) currentModel = model;
      continue;
    }

    if (type === "event_msg" && obj.payload?.type === "token_count") {
      const payload = obj.payload;
      // rate_limits snapshot (display data only — never summed). Latest by ts.
      const rl = payload.rate_limits;
      if (rl && typeof rl === "object") {
        rateLimits = rl;
        rateLimitsAsOf = typeof obj.timestamp === "string" ? obj.timestamp : null;
      }
      // whitelist: payload.info.total_token_usage
      const info = payload.info;
      if (!info) continue; // occasionally null — nothing to fold
      const T = info.total_token_usage;
      if (!T || typeof T !== "object") continue;

      const curInput = T.input_tokens || 0;
      const curCached = T.cached_input_tokens || 0;
      const curOutput = T.output_tokens || 0;

      const dInput = deltaFor(curInput, prev.input);
      const dCached = deltaFor(curCached, prev.cached);
      const dOutput = deltaFor(curOutput, prev.output);
      prev.input = curInput;
      prev.cached = curCached;
      prev.output = curOutput;

      // All-zero deltas ⇒ duplicate pair ⇒ emit nothing.
      if (dInput === 0 && dCached === 0 && dOutput === 0) continue;

      // Canonical class mapping. OpenAI: cached ⊂ input, reasoning ⊂ output —
      // so the plain-input piece is input minus cached; output is used as-is
      // (reasoning already inside it, never added on top). cacheCreate has no
      // Codex analog.
      const usage = {
        input_tokens: Math.max(0, dInput - dCached),
        cache_read_input_tokens: dCached,
        cache_creation_input_tokens: 0,
        output_tokens: dOutput,
      };

      records.push({
        messageId: "codex:" + (sessionId ?? uuidFromFileName(fileName) ?? "<unknown>"),
        requestId: "token:" + seq++,
        model: currentModel ?? "<codex-unknown>",
        usage,
        timestamp: typeof obj.timestamp === "string" ? obj.timestamp : undefined,
        provider: "codex",
        isSidechain: false,
      });
      continue;
    }
    // Any other line (response_item, task_started, …) is ignored WITHOUT
    // decoding its content — the whitelist above is the only thing we read.
  }

  return {
    records,
    malformed,
    rateLimits: rateLimits ? { ...rateLimits, asOf: rateLimitsAsOf } : null,
  };
}

// Stream one file's lines through the pure fold. Kept out of the pure function
// so the fold stays trivially fixture-testable.
async function readCodexFile(path) {
  const lines = [];
  try {
    const rl = createInterface({ input: createReadStream(path), crlfDelay: Infinity });
    for await (const line of rl) lines.push(line);
  } catch {
    // File vanished / unreadable mid-read — fold whatever we got. A partial
    // trailing line just counts as malformed.
  }
  const fileName = path.slice(path.lastIndexOf("/") + 1);
  return recordsFromCodexLines(lines, { fileName });
}

/**
 * Read all Codex usage under `root`.
 * @returns {Promise<{records:object[], malformed:number, codexRateLimits:object|null}>}
 *   codexRateLimits = the globally latest snapshot (by asOf) across all files.
 */
export async function readCodexUsage(root) {
  const files = findCodexJsonl(root);
  const records = [];
  let malformed = 0;
  let codexRateLimits = null;
  for (const path of files) {
    const r = await readCodexFile(path);
    for (const rec of r.records) records.push(rec);
    malformed += r.malformed;
    if (r.rateLimits) {
      // latest-wins by asOf timestamp; a snapshot without asOf never displaces
      // one that has a real timestamp.
      if (!codexRateLimits) codexRateLimits = r.rateLimits;
      else {
        const a = codexRateLimits.asOf ? Date.parse(codexRateLimits.asOf) : NaN;
        const b = r.rateLimits.asOf ? Date.parse(r.rateLimits.asOf) : NaN;
        if (!isNaN(b) && (isNaN(a) || b >= a)) codexRateLimits = r.rateLimits;
      }
    }
  }
  return { records, malformed, codexRateLimits };
}
