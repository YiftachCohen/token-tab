// Token Tab — price table + cost math (pure, no I/O, no dependencies).
//
// Dollars are an ESTIMATE, not an invoice (this is a stated premise of the design:
// "good enough to know your tab, not good enough for accounting"). It is a bundled
// per-model rate table applied to the four token classes the logs already carry —
// no network call, no key, nothing retrieved. Just arithmetic on numbers already on disk.
//
// Rates are USD per MILLION tokens, from Anthropic's public list pricing. Input and
// output are listed per model; the two cache classes are derived from the input rate
// using Anthropic's published multipliers:
//   cache WRITE (cache_creation_input_tokens) = 1.25x input  — the 5-minute-TTL write
//        rate. The logs don't record the TTL, so we assume 5m (what ccusage assumes too).
//   cache READ  (cache_read_input_tokens)      = 0.10x input
//
// Unknown models are NEVER invented a price for. costOfUsage returns priced:false and
// the caller still counts the tokens — "tracked tokens, untracked price." A guessed
// dollar figure that disagrees with the real bill is worse than honestly saying "unknown."

import { usageByClass, normalizeModel } from "./core.mjs";

const CACHE_WRITE_MULT = 1.25; // 5-minute cache-write rate, relative to input
const CACHE_READ_MULT = 0.1; // cache-read rate, relative to input

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
  "claude-opus-4-8": { input: 5, output: 25 },
  "claude-opus-4-7": { input: 5, output: 25 },
  "claude-opus-4-6": { input: 5, output: 25 },
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
  opus: "claude-opus-4-8",
  sonnet: "claude-sonnet-4-6",
  haiku: "claude-haiku-4-5",
};

/** Reduce any model id to the rate-table key:
 *  - strip the [1m] suffix (same surface, same price on current models)
 *  - strip Bedrock region prefixes (us./eu./apac.) and the `anthropic.` vendor prefix
 *  - strip the Bedrock `-vN:M` version suffix and a trailing `-YYYYMMDD` snapshot date
 *  So `us.anthropic.claude-opus-4-8-20251101-v1:0` and `claude-opus-4-8[1m]` both → `claude-opus-4-8`.
 *  Bedrock thus reuses the list-price table (region surcharges are not modeled — part of the stated tolerance). */
export function canonicalModelId(model) {
  let id = normalizeModel(model).base;
  if (typeof id !== "string") return "";
  id = id.toLowerCase();
  id = id.replace(/^(us|eu|apac|us-gov)\./, ""); // Bedrock region prefix
  id = id.replace(/^anthropic\./, ""); // Bedrock vendor prefix
  id = id.replace(/-v\d+:\d+$/, ""); // Bedrock version suffix
  id = id.replace(/-\d{8}$/, ""); // dated snapshot suffix (e.g. -20251001)
  return id;
}

/** Per-class USD-per-million rates for a model, or null when it isn't in the table. */
export function ratesFor(model) {
  const id = canonicalModelId(model);
  const base = RATES[id] || RATES[ALIASES[id]];
  if (!base) return null;
  return {
    input: base.input,
    cacheWrite: base.input * CACHE_WRITE_MULT,
    cacheRead: base.input * CACHE_READ_MULT,
    output: base.output,
  };
}

/** Cost of one usage block under a model. Returns {usd, priced}: priced:false means
 *  the model isn't in the table — usd is 0 and the caller should track tokens, not dollars. */
export function costOfUsage(usage, model) {
  const r = ratesFor(model);
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
