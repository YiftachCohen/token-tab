// Token Tab — price table + cost math (pure, no I/O, no dependencies).
//
// Dollars are an ESTIMATE, not an invoice (this is a stated premise of the design:
// "good enough to know your tab, not good enough for accounting"). It is a bundled
// per-model rate table applied to the four token classes the logs already carry —
// no network call, no key, nothing retrieved. Just arithmetic on numbers already on disk.
//
// Rates are USD per MILLION tokens. Input and output are listed per model; the two
// cache classes are derived from the input rate using PER-PROVIDER multipliers (the
// cache economics differ between vendors — see CACHE_MULTIPLIERS below):
//   Claude: cache WRITE (cache_creation_input_tokens) = 1.25x input — the 5-minute-TTL
//        write rate. The logs don't record the TTL, so we assume 5m (what ccusage assumes too).
//        cache READ (cache_read_input_tokens) = 0.10x input.
//   Codex (OpenAI): cache WRITE = 0 (OpenAI doesn't bill a separate cache-write step —
//        prompt caching is automatic and free to populate). cache READ = 0.10x input,
//        same ratio as Claude (verified against OpenAI's pricing page).
//
// Unknown models are NEVER invented a price for. costOfUsage returns priced:false and
// the caller still counts the tokens — "tracked tokens, untracked price." A guessed
// dollar figure that disagrees with the real bill is worse than honestly saying "unknown."

import { usageByClass, normalizeModel } from "./core.mjs";

// Per-provider cache multipliers, relative to each model's own input rate (design
// doc section 3). Claude keeps its historical write/read split; Codex never bills a
// cache-write step, only a discounted cache-read.
const CACHE_MULTIPLIERS = {
  claude: { write: 1.25, read: 0.1 },
  codex: { write: 0, read: 0.1 },
};

// input / output USD per 1M tokens, from Anthropic's published list pricing. Covers every
// model Anthropic still publishes a standard rate for — current models plus older ones that
// remain billable (several only on Bedrock/Vertex now). Models with NO published rate
// (e.g. Haiku 3) and synthetic ids fall through to unpriced on purpose — a guessed figure
// is worse than an honest "no rate." The 1M-context tier ([1m] suffix) is standard-priced
// on current models (no long-context premium), so it shares the base rate — normalizeModel
// strips the suffix before lookup.
const RATES = {
  // Current models.
  "claude-fable-5": { input: 10, output: 50 },
  "claude-opus-5": { input: 5, output: 25 },
  "claude-opus-4-8": { input: 5, output: 25 },
  "claude-opus-4-7": { input: 5, output: 25 },
  "claude-opus-4-6": { input: 5, output: 25 },
  // Sonnet 5 list price. Anthropic is running a $2/$10 introductory rate through
  // 2026-08-31, but the table isn't date-aware and documents itself as list pricing —
  // the intro discount would silently go stale on 2026-09-01. (Same as Sonnet 4.6.)
  "claude-sonnet-5": { input: 3, output: 15 },
  "claude-sonnet-4-6": { input: 3, output: 15 },
  "claude-haiku-4-5": { input: 1, output: 5 },
  // Older, still-billable models. canonicalModelId reduces dated/Bedrock ids to these keys
  // (e.g. claude-sonnet-4-20250514 and anthropic.claude-sonnet-4-...-v1:0 -> claude-sonnet-4).
  "claude-opus-4-5": { input: 5, output: 25 },
  "claude-opus-4-1": { input: 15, output: 75 },
  "claude-opus-4": { input: 15, output: 75 },
  "claude-sonnet-4-5": { input: 3, output: 15 },
  "claude-sonnet-4": { input: 3, output: 15 },
  "claude-3-5-haiku": { input: 0.8, output: 4 },
};

// Bare aliases Claude Code sometimes writes (e.g. "sonnet") resolve to the current
// model in that family. This is the same family→latest mapping the official tooling uses.
const ALIASES = {
  opus: "claude-opus-5",
  sonnet: "claude-sonnet-5",
  haiku: "claude-haiku-4-5",
};

// ---------------------------------------------------------------------------
// OpenAI (Codex) rate table — kept in its own map so the Claude table above
// stays visually intact. Entries VERIFIED 2026-07-31 against OpenAI's per-model
// API docs pages (standard tier). OpenAI model ids are already clean (no dated
// snapshot / region prefix to strip) — just lowercase.
//
// The GPT-5.6 family (Sol/Terra/Luna) went GA in Codex on 2026-07-09 and is now the
// bulk of Codex traffic, so its absence here was not an edge case — it was most of
// the bill. NOTE for the next update: Terra and Luna were REPRICED DOWN on 2026-07-30
// (terra $2.50/$15 -> $2.00/$12, luna $1.00/$6 -> $0.20/$1.20). Most third-party
// pricing pages still quote the launch rates; read OpenAI's own model pages.
//
// Cached input is 0.10x input for every entry here, which is what CACHE_MULTIPLIERS.codex
// already encodes. Long-context (>272K input) surcharges are NOT modeled, consistent with
// the rest of the table — see the stated tolerance in the file header.
//
// Deliberately absent (NO published rate we could verify — never guess, see file header):
// gpt-5.3-codex-spark (research preview, "credit rates not final"), gpt-5.4-codex (no such
// published model; a handful of stray log records), codex-auto-review (internal Codex slug),
// <codex-unknown>. gpt-5.4-pro/gpt-5.5-pro are absent for a different reason — they're
// priced, but they aren't Codex CLI models. NO entry → the caller's unpriced bucket.
const OPENAI_RATES = {
  "gpt-5.6-sol": { input: 5.0, output: 30.0 },
  "gpt-5.6-terra": { input: 2.0, output: 12.0 },
  "gpt-5.6-luna": { input: 0.2, output: 1.2 },
  "gpt-5.5": { input: 5.0, output: 30.0 },
  "gpt-5.4": { input: 2.5, output: 15.0 },
  "gpt-5.4-mini": { input: 0.75, output: 4.5 },
  "gpt-5.4-nano": { input: 0.2, output: 1.25 },
  "gpt-5.3-codex": { input: 1.75, output: 14.0 },
  "gpt-5.2-codex": { input: 1.75, output: 14.0 },
  "gpt-5.1-codex": { input: 1.25, output: 10.0 },
  "gpt-5.1-codex-max": { input: 1.25, output: 10.0 },
  "gpt-5-codex": { input: 1.25, output: 10.0 },
};

// Per-provider {rates, aliases} lookup, keyed exactly like classifySurface/costOfUsage's
// `provider` argument. Unknown providers fall back to "claude" (matches aggregate()'s
// "absent provider ⇒ claude" convention).
const TABLES = {
  claude: { rates: RATES, aliases: ALIASES },
  codex: { rates: OPENAI_RATES, aliases: {} },
};

function tableFor(provider) {
  return TABLES[provider] || TABLES.claude;
}

/** The rate-table's model keys, exported so tests can assert the shared parity
 *  fixture covers the table exhaustively (see test/rates-coverage.test.mjs). Claude-only
 *  by default for back-compat; pass a provider to get that provider's keys. */
export function ratedModelIds(provider = "claude") {
  return Object.freeze(Object.keys(tableFor(provider).rates));
}
export function aliasIds(provider = "claude") {
  return Object.freeze(Object.keys(tableFor(provider).aliases));
}
// Back-compat plain-array exports (Claude table) — existing callers (JS rates-coverage
// test) import these directly without a provider argument.
export const RATED_MODEL_IDS = ratedModelIds("claude");
export const ALIAS_IDS = aliasIds("claude");
// Codex-side equivalents, for the (provider, model)-keyed coverage test.
export const OPENAI_RATED_MODEL_IDS = ratedModelIds("codex");

/** Reduce any model id to the rate-table key.
 *  Claude: strip the [1m] suffix (same surface, same price on current models); strip
 *  Bedrock region prefixes (us./eu./apac.) and the `anthropic.` vendor prefix; strip the
 *  Bedrock `-vN:M` version suffix and a trailing `-YYYYMMDD` snapshot date. So
 *  `us.anthropic.claude-opus-4-8-20251101-v1:0` and `claude-opus-4-8[1m]` both → `claude-opus-4-8`.
 *  Bedrock thus reuses the list-price table (region surcharges are not modeled — part of the stated tolerance).
 *  Codex: OpenAI ids are already clean — just lowercase, no prefix/suffix stripping. */
export function canonicalModelId(model, provider = "claude") {
  let id = normalizeModel(model).base;
  if (typeof id !== "string") return "";
  id = id.toLowerCase();
  if (provider === "codex") return id; // OpenAI ids need no further normalization
  id = id.replace(/^(us|eu|apac|us-gov)\./, ""); // Bedrock region prefix
  id = id.replace(/^anthropic\./, ""); // Bedrock vendor prefix
  id = id.replace(/-v\d+:\d+$/, ""); // Bedrock version suffix
  id = id.replace(/-\d{8}$/, ""); // dated snapshot suffix (e.g. -20251001)
  return id;
}

/** Per-class USD-per-million rates for a model, or null when it isn't in the table. */
export function ratesFor(model, provider = "claude") {
  const { rates, aliases } = tableFor(provider);
  const id = canonicalModelId(model, provider);
  const base = rates[id] || rates[aliases[id]];
  if (!base) return null;
  const mult = CACHE_MULTIPLIERS[provider] || CACHE_MULTIPLIERS.claude;
  return {
    input: base.input,
    cacheWrite: base.input * mult.write,
    cacheRead: base.input * mult.read,
    output: base.output,
  };
}

/** Cost of one usage block under a model. Returns {usd, priced}: priced:false means
 *  the model isn't in the table — usd is 0 and the caller should track tokens, not dollars.
 *  `provider` selects the canonicalizer + rate table + cache multipliers (default "claude",
 *  matching aggregate()'s "absent provider ⇒ claude" convention). */
export function costOfUsage(usage, model, provider = "claude") {
  const r = ratesFor(model, provider);
  if (!r) return { usd: 0, priced: false };
  const c = usageByClass(usage);
  const usd =
    (c.input * r.input +
      c.cacheCreate * r.cacheWrite +
      c.cacheRead * r.cacheRead +
      c.output * r.output) /
    1e6;
  return { usd, priced: true };
}
