// Token Tab — pure parsing core.
//
// No I/O, no dependencies. Takes already-parsed JSONL objects and returns an
// aggregate. Keeping this pure is what lets golden-fixture tests pin every edge
// case (see the test plan) without touching the filesystem or a sandbox.
//
// It never touches `message.content` — only the metadata fields needed to count
// tokens. That is the whole trust story: we read the numbers, never your text.

/** Sum of all four token classes — matches ccusage's default total. cache_read
 * usually dominates, so leaving it out would diverge wildly. */
export function usageSum(u) {
  if (!u) return 0;
  return (
    (u.input_tokens || 0) +
    (u.cache_creation_input_tokens || 0) +
    (u.cache_read_input_tokens || 0) +
    (u.output_tokens || 0)
  );
}

export function usageByClass(u) {
  return {
    input: u?.input_tokens || 0,
    cacheCreate: u?.cache_creation_input_tokens || 0,
    cacheRead: u?.cache_read_input_tokens || 0,
    output: u?.output_tokens || 0,
  };
}

/** Strip the `[1m]` 1M-context suffix; report whether it was present (it's a
 * distinct price tier for the dollars layer later). */
export function normalizeModel(model) {
  if (typeof model !== "string") return { base: "<unknown>", oneM: false };
  const oneM = model.endsWith("[1m]");
  return { base: oneM ? model.slice(0, -4) : model, oneM };
}

/** Route a model id to a billing surface.
 *  codex:        provider === "codex" (Claude routing below is untouched otherwise)
 *  bedrock:      us.anthropic.* / anthropic.*:0
 *  subscription: claude-* and bare names (sonnet/opus/haiku)
 *  untracked:    <synthetic> and anything unrecognized (still counted for tokens) */
export function classifySurface(model, provider) {
  if (provider === "codex") return "codex";
  const { base } = normalizeModel(model);
  if (!base || base === "<synthetic>" || base === "<unknown>") return "untracked";
  // Bedrock ids carry an optional region prefix (us./eu./apac./us-gov.) before
  // `anthropic.`; strip it so every region routes to bedrock — matching the
  // region set canonicalModelId strips in pricing.mjs (kept in lockstep).
  const deregioned = base.replace(/^(us|eu|apac|us-gov)\./, "");
  if (deregioned.startsWith("anthropic.")) return "bedrock";
  if (base.startsWith("claude-") || /^(sonnet|opus|haiku)$/i.test(base)) return "subscription";
  return "untracked";
}

const FIVE_HOURS_MS = 5 * 60 * 60 * 1000;

function localDayKey(d) {
  // YYYY-MM-DD in LOCAL time (logs are UTC; "today" must mean the user's day).
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function startOfLocalWeek(now, weekStartsOn /* 0=Sun,1=Mon */) {
  const d = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const diff = (d.getDay() - weekStartsOn + 7) % 7;
  d.setDate(d.getDate() - diff);
  return d;
}


/**
 * Aggregate a stream of assistant usage records.
 *
 * @param {Iterable<{messageId?:string,requestId?:string,model:string,usage:object,timestamp:string,isSidechain?:boolean,provider?:string}>} records
 *   `provider` is optional and defaults to "claude" (absent ⇒ "claude", so old fixtures/
 *   caches with no provider field aggregate exactly as before).
 * @param {{now?:Date, weekStartsOn?:number, cost?:(usage:object,model:string,provider?:string)=>{usd:number,priced:boolean}, codexRateLimits?:object}} opts
 *   opts.cost (optional): a pure pricing function (see src/pricing.mjs). Called with the
 *   record's provider (default "claude") so it can select the right rate table + cache
 *   multipliers. When supplied, the result carries a `cost` block (dollars per window +
 *   per model). Omit it and the output is byte-for-byte unchanged — the dollars layer
 *   never alters the token numbers.
 *   opts.codexRateLimits (optional): out-of-band official snapshot
 *   `{primary:{used_percent,resets_at,window_minutes}, secondary:{...}, plan_type, asOf}`
 *   from the newest Codex `token_count` event. Formatted into `providers.codex.windows`
 *   and `providers.codex.plan` — never summed into any token/dollar total.
 * @returns aggregate snapshot (plain value object — no content, no PII)
 */
export function aggregate(records, opts = {}) {
  const now = opts.now ? new Date(opts.now) : new Date();
  const weekStartsOn = opts.weekStartsOn ?? 1; // Monday
  const costFn = typeof opts.cost === "function" ? opts.cost : null;
  const todayKey = localDayKey(now);
  const weekStart = startOfLocalWeek(now, weekStartsOn).getTime();
  const rollingCutoff = now.getTime() - FIVE_HOURS_MS;

  // Pass 1 — dedup with KEEP-LAST resolution.
  // Key = `${messageId}:${requestId}` when BOTH exist; otherwise a unique key (so a
  // line missing an id is always counted, never collapsed).
  // Streaming emits several usage lines per message sharing one key; input/cache
  // are constant across them but `output_tokens` GROWS, so the FINAL line is
  // authoritative. Keeping last (verified against ccusage: output reconciles only
  // with last-write-wins) — collisions with differing totals are still reported.
  const kept = new Map(); // key -> record (last seen)
  let uniqueCounter = 0;
  let duplicatesDropped = 0;
  let collisionsDifferingTotals = 0;
  let approximate = false;

  for (const r of records) {
    const hasIds = !!(r.messageId && r.requestId);
    const key = hasIds ? `${r.messageId}:${r.requestId}` : `__nokey__${uniqueCounter++}`;
    if (!hasIds) approximate = true;
    if (kept.has(key)) {
      duplicatesDropped++;
      if (usageSum(kept.get(key).usage) !== usageSum(r.usage)) collisionsDifferingTotals++;
    }
    kept.set(key, r); // last-write-wins (records arrive in deterministic file-mtime+line order)
  }

  // Pass 2 — aggregate the deduped records. Combined (all-provider) totals AND
  // per-provider subtotals are accumulated side-by-side in the same loop so a
  // Claude-only input produces byte-identical combined output to before providers
  // existed (the per-provider bucket for "claude" just mirrors the combined one).
  const byClass = { input: 0, cacheCreate: 0, cacheRead: 0, output: 0 };
  const bySurface = {}; // surface -> tokens
  const byModel = {}; // base model -> tokens
  let total = 0;
  let today = 0;
  let thisWeek = 0;
  let rolling5h = 0;
  let counted = 0;
  let untrackedTokens = 0;
  let untrackedRequests = 0;
  // Dollars (only when a pricing fn is injected). Mirrors the token windows so the
  // estimate can be shown per today/week/5h. "unpriced" = a model with no rate in the
  // table: its tokens still count everywhere else, just not toward dollars.
  let costTotal = 0;
  let costToday = 0;
  let costWeek = 0;
  let costRolling = 0;
  const costByModel = {};
  let unpricedTokens = 0;
  let unpricedRequests = 0;
  const unpricedModels = new Set();
  // {t, sum} for the window pass (past-dated CLAUDE records only). The inferred 5h
  // block is Anthropic's rate-limit window: feeding another provider's timestamps into
  // it would inflate Claude's window tokens (and its cap %) with usage Anthropic never
  // billed — a Codex-heavy trace could read as 100% of the Claude cap. See providers.*
  // for each provider's own window (Codex's is official, never inferred).
  const stamps = [];

  // Per-provider subtotals (providers.<p>.*) — only the fields the spec's schema
  // needs (today/total/thisWeek/rolling5h/byClass/byModel/bySurface). One bucket
  // per provider seen, created lazily so absent providers never appear in output.
  const providerOrder = []; // first-seen order
  const providerBuckets = new Map(); // provider -> bucket
  function providerBucket(p) {
    let b = providerBuckets.get(p);
    if (!b) {
      b = {
        total: 0,
        today: 0,
        thisWeek: 0,
        rolling5h: 0,
        byClass: { input: 0, cacheCreate: 0, cacheRead: 0, output: 0 },
        byModel: {},
        bySurface: {},
        // Dollars scoped to this provider (populated only when opts.cost is supplied).
        // The combined cost.* block is every provider's spend added together; a UI that
        // labels a figure "Claude" needs Claude's own, or a priced Codex record inflates it.
        cost: { total: 0, today: 0, thisWeek: 0, rolling5h: 0 },
      };
      providerBuckets.set(p, b);
      providerOrder.push(p);
    }
    return b;
  }

  for (const r of kept.values()) {
    const sum = usageSum(r.usage);
    counted++;
    total += sum;
    const c = usageByClass(r.usage);
    byClass.input += c.input;
    byClass.cacheCreate += c.cacheCreate;
    byClass.cacheRead += c.cacheRead;
    byClass.output += c.output;

    const provider = r.provider || "claude";
    const pb = providerBucket(provider);
    pb.total += sum;
    pb.byClass.input += c.input;
    pb.byClass.cacheCreate += c.cacheCreate;
    pb.byClass.cacheRead += c.cacheRead;
    pb.byClass.output += c.output;

    const surface = classifySurface(r.model, provider);
    bySurface[surface] = (bySurface[surface] || 0) + sum;
    pb.bySurface[surface] = (pb.bySurface[surface] || 0) + sum;
    const { base } = normalizeModel(r.model);
    byModel[base] = (byModel[base] || 0) + sum;
    pb.byModel[base] = (pb.byModel[base] || 0) + sum;
    if (surface === "untracked") {
      untrackedTokens += sum;
      untrackedRequests++;
    }

    let usd = 0;
    let priced = false;
    if (costFn) {
      const c2 = costFn(r.usage, r.model, provider);
      usd = c2.usd || 0;
      priced = !!c2.priced;
      if (priced) {
        costTotal += usd;
        pb.cost.total += usd;
        costByModel[base] = (costByModel[base] || 0) + usd;
      } else {
        unpricedTokens += sum;
        unpricedRequests++;
        unpricedModels.add(base);
      }
    }

    const ts = new Date(r.timestamp);
    if (!isNaN(ts)) {
      // Upper-bound every window at `now` so a future-dated line (clock skew)
      // can't inflate today/week/5h. Total still includes it — it's real spend,
      // just mis-stamped. Makes rolling5h the documented half-open (now-5h, now].
      const tms = ts.getTime();
      if (tms <= now.getTime()) {
        const isToday = localDayKey(ts) === todayKey;
        if (isToday) { today += sum; pb.today += sum; }
        if (tms >= weekStart) { thisWeek += sum; pb.thisWeek += sum; }
        if (tms > rollingCutoff) { rolling5h += sum; pb.rolling5h += sum; }
        if (priced) {
          if (isToday) { costToday += usd; pb.cost.today += usd; }
          if (tms >= weekStart) { costWeek += usd; pb.cost.thisWeek += usd; }
          if (tms > rollingCutoff) { costRolling += usd; pb.cost.rolling5h += usd; }
        }
        if (provider === "claude") stamps.push({ t: tms, sum });
      }
    }
  }

  // Pass 3 — Claude's current usage window (Anthropic-style fixed 5h reset blocks), built
  // from CLAUDE records only (see `stamps` above — other providers have their own windows).
  // A block starts at the EXACT first message (verified: Claude anchors the window to
  // your first message, not the top of the hour) and lasts blockHours; a gap >
  // blockHours, or crossing the block end, starts a new block. The reset time is exact.
  // The % needs the plan cap, which Anthropic does not publish — so pct is only given
  // when opts.cap is supplied. calibratedCap (busiest completed block) is exposed as
  // info but is NOT used as a denominator: you've usually never maxed a window, so it
  // would over-report how close you are. Set the cap from Claude's /usage to get a %.
  const blockMs = (opts.blockHours ?? 5) * 60 * 60 * 1000;
  stamps.sort((a, b) => a.t - b.t);
  const blocks = [];
  for (const s of stamps) {
    const last = blocks[blocks.length - 1];
    if (last && s.t - last.lastT <= blockMs && s.t < last.start + blockMs) {
      last.tokens += s.sum;
      last.lastT = s.t;
    } else {
      blocks.push({ start: s.t, lastT: s.t, tokens: s.sum });
    }
  }
  const nowMs = now.getTime();
  const lastBlock = blocks[blocks.length - 1] || null;
  const windowActive = !!(lastBlock && nowMs >= lastBlock.start && nowMs < lastBlock.start + blockMs);
  const completed = windowActive ? blocks.slice(0, -1) : blocks;
  const calibratedCap = completed.reduce((m, b) => Math.max(m, b.tokens), 0);
  const cap = opts.cap != null && opts.cap > 0 ? opts.cap : 0;
  const windowTokens = windowActive ? lastBlock.tokens : 0;
  const resetAt = windowActive ? lastBlock.start + blockMs : null;
  const windowStats = {
    active: windowActive,
    tokens: windowTokens,
    resetAt, // ms epoch, or null when no active block
    msToReset: resetAt != null ? resetAt - nowMs : null,
    cap, // 0 when no configured cap
    calibratedCap, // busiest completed block — informational only
    capSource: cap > 0 ? "config" : "none",
    pct: cap > 0 ? Math.round((windowTokens / cap) * 100) : null,
  };

  // providers.<p>.windows (spec section 4/5). Claude's primary window is just windowStats
  // (computed above from Claude's records alone), tagged with source/period metadata. Codex
  // gets an "official" window formatted from an out-of-band snapshot the caller supplies —
  // never computed/summed from records, because OpenAI publishes the real percentage.
  const providers = {};
  for (const p of providerOrder) {
    const pb = providerBuckets.get(p);
    const entry = {
      today: pb.today,
      total: pb.total,
      thisWeek: pb.thisWeek,
      rolling5h: pb.rolling5h,
      byClass: pb.byClass,
      byModel: pb.byModel,
      bySurface: pb.bySurface,
    };
    // Mirrors the top-level rule: the cost block exists only when a pricing fn was injected.
    if (costFn) entry.cost = pb.cost;
    if (p === "claude") {
      entry.windows = {
        primary: { ...windowStats, source: "inferred", period: "5h" },
      };
    }
    providers[p] = entry;
  }

  // Codex's windows come entirely from an out-of-band official snapshot (never
  // derived from records — Phase 1 has no Codex reader). Formatting only: if the
  // caller passes opts.codexRateLimits, surface it as providers.codex.windows/plan,
  // creating the codex provider entry if Codex had no records of its own yet.
  if (opts.codexRateLimits) {
    const snap = opts.codexRateLimits;
    if (!providers.codex) {
      providers.codex = {
        today: 0,
        total: 0,
        thisWeek: 0,
        rolling5h: 0,
        byClass: { input: 0, cacheCreate: 0, cacheRead: 0, output: 0 },
        byModel: {},
        bySurface: {},
        ...(costFn ? { cost: { total: 0, today: 0, thisWeek: 0, rolling5h: 0 } } : {}),
      };
      if (!providerOrder.includes("codex")) providerOrder.push("codex");
    }
    // resetAt/asOf are normalized to epoch ms here (not left as raw ISO strings) so
    // providers.codex.windows.*.resetAt is consistent with the legacy top-level
    // `window.resetAt` (also epoch ms) — one shape for "when does this reset" across
    // the whole schema. Swift already parses these into `Date`; this only affects the
    // JS aggregate() output.
    const toEpochMs = (v) => {
      // Real Codex logs carry resets_at as epoch SECONDS (asOf is an ISO string);
      // accept both, tolerating ms-epoch numbers just in case.
      if (typeof v === "number" && Number.isFinite(v)) {
        return Math.round(v >= 1e12 ? v : v * 1000);
      }
      if (typeof v !== "string") return null;
      const ms = Date.parse(v);
      return isNaN(ms) ? null : ms;
    };
    // A window without used_percent is dropped whole (matches the Swift reader).
    const fmtWindow = (w, period) =>
      w && w.used_percent != null
        ? {
            source: "official",
            period,
            usedPct: w.used_percent ?? null,
            resetAt: toEpochMs(w.resets_at),
            windowMinutes: w.window_minutes ?? null,
            cap: null,
            calibratedCap: null,
          }
        : undefined;
    // The raw primary/secondary field names are not semantic. In current Codex logs a
    // weekly-only allowance can arrive in `primary`; window_minutes is the authoritative
    // discriminator. Keep unknown/missing durations in their raw fallback slot so an older
    // producer does not lose data, but let a declared duration win any collision.
    const classified = {};
    const priority = {};
    for (const [fallbackKey, w] of [
      ["primary", snap.primary],
      ["secondary", snap.secondary],
    ]) {
      if (!w || w.used_percent == null) continue;
      const declared = w.window_minutes === 300 || w.window_minutes === 10080;
      const key = w.window_minutes === 300 ? "primary" : w.window_minutes === 10080 ? "secondary" : fallbackKey;
      const period = key === "primary" ? "5h" : "weekly";
      const rank = declared ? 1 : 0;
      if (!(key in classified) || rank > priority[key]) {
        classified[key] = fmtWindow(w, period);
        priority[key] = rank;
      }
    }
    providers.codex.windows = classified;
    providers.codex.plan = { planType: snap.plan_type ?? null, asOf: toEpochMs(snap.asOf) };
  }

  return {
    schemaVersion: 2,
    total,
    byClass,
    bySurface,
    byModel,
    today,
    thisWeek,
    rolling5h,
    window: windowStats,
    providerOrder,
    providers,
    dedup: { counted, duplicatesDropped, collisionsDifferingTotals },
    approximate,
    untracked: { tokens: untrackedTokens, requests: untrackedRequests },
    // Present only when opts.cost was supplied. Dollars are an estimate; `unpriced`
    // records the tokens we counted but had no rate for (honest gap, never guessed).
    cost: costFn
      ? {
          total: costTotal,
          today: costToday,
          thisWeek: costWeek,
          rolling5h: costRolling,
          byModel: costByModel,
          unpriced: {
            tokens: unpricedTokens,
            requests: unpricedRequests,
            models: [...unpricedModels].sort(),
          },
        }
      : undefined,
  };
}

/** Extract the fields we care about from a raw JSONL object. Returns null for
 * any line that is not an assistant turn carrying usage. Never reads content. */
export function recordFromLine(obj) {
  if (!obj || obj.type !== "assistant") return null;
  const usage = obj.message?.usage;
  if (!usage) return null;
  return {
    messageId: obj.message?.id,
    requestId: obj.requestId,
    model: obj.message?.model ?? "<unknown>",
    usage,
    timestamp: obj.timestamp,
    isSidechain: !!obj.isSidechain, // counted, NOT filtered — sidechains are real spend
  };
}
