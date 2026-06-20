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
 *  bedrock:      us.anthropic.* / anthropic.*:0
 *  subscription: claude-* and bare names (sonnet/opus/haiku)
 *  untracked:    <synthetic> and anything unrecognized (still counted for tokens) */
export function classifySurface(model) {
  const { base } = normalizeModel(model);
  if (!base || base === "<synthetic>" || base === "<unknown>") return "untracked";
  if (base.startsWith("us.anthropic.") || /^anthropic\..*:\d+$/.test(base) || base.startsWith("anthropic."))
    return "bedrock";
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
 * @param {Iterable<{messageId?:string,requestId?:string,model:string,usage:object,timestamp:string,isSidechain?:boolean}>} records
 * @param {{now?:Date, weekStartsOn?:number}} opts
 * @returns aggregate snapshot (plain value object — no content, no PII)
 */
export function aggregate(records, opts = {}) {
  const now = opts.now ? new Date(opts.now) : new Date();
  const weekStartsOn = opts.weekStartsOn ?? 1; // Monday
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

  // Pass 2 — aggregate the deduped records.
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

  for (const r of kept.values()) {
    const sum = usageSum(r.usage);
    counted++;
    total += sum;
    const c = usageByClass(r.usage);
    byClass.input += c.input;
    byClass.cacheCreate += c.cacheCreate;
    byClass.cacheRead += c.cacheRead;
    byClass.output += c.output;

    const surface = classifySurface(r.model);
    bySurface[surface] = (bySurface[surface] || 0) + sum;
    const { base } = normalizeModel(r.model);
    byModel[base] = (byModel[base] || 0) + sum;
    if (surface === "untracked") {
      untrackedTokens += sum;
      untrackedRequests++;
    }

    const ts = new Date(r.timestamp);
    if (!isNaN(ts)) {
      if (localDayKey(ts) === todayKey) today += sum;
      if (ts.getTime() >= weekStart) thisWeek += sum;
      if (ts.getTime() > rollingCutoff) rolling5h += sum;
    }
  }

  return {
    total,
    byClass,
    bySurface,
    byModel,
    today,
    thisWeek,
    rolling5h,
    dedup: { counted, duplicatesDropped, collisionsDifferingTotals },
    approximate,
    untracked: { tokens: untrackedTokens, requests: untrackedRequests },
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
