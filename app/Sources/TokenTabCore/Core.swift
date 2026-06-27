// Token Tab — pure parsing/aggregation core (Swift port of ../../src/core.mjs).
//
// No I/O, no network. Takes already-parsed usage records and returns an aggregate.
// Keeping this pure is what lets the tests pin every edge case (dedup, windowing,
// surface routing) without a filesystem — exactly as the JS core does. It never sees
// `message.content`; the I/O shell (LogReader) only ever hands it the metadata fields.
//
// Parity with the JS engine is intentional and load-bearing: the dedup rule
// (`messageId:requestId`, keep-last), the four-class token sum, the surface routing,
// and the fixed 5-hour window blocks are ported one-for-one so the native app's
// numbers reconcile with the audited `src/` engine (and thus with ccusage).

import Foundation

// MARK: - Input record

/// One assistant usage record, stripped to the fields we count. Never carries content.
public struct UsageRecord: Sendable {
    public var messageId: String?
    public var requestId: String?
    public var model: String
    public var usage: TokenUsage
    public var timestamp: Date?
    public var isSidechain: Bool

    public init(messageId: String?, requestId: String?, model: String,
                usage: TokenUsage, timestamp: Date?, isSidechain: Bool) {
        self.messageId = messageId
        self.requestId = requestId
        self.model = model
        self.usage = usage
        self.timestamp = timestamp
        self.isSidechain = isSidechain
    }
}

/// The four token classes the logs carry. cache_read usually dominates volume.
public struct TokenUsage: Sendable {
    public var input: Int
    public var cacheCreate: Int
    public var cacheRead: Int
    public var output: Int

    public init(input: Int = 0, cacheCreate: Int = 0, cacheRead: Int = 0, output: Int = 0) {
        self.input = input
        self.cacheCreate = cacheCreate
        self.cacheRead = cacheRead
        self.output = output
    }

    /// Sum of all four classes — matches ccusage's default total. Leaving cache_read
    /// out (it dominates) would diverge wildly, so every class counts.
    public var sum: Int { input + cacheCreate + cacheRead + output }
}

// MARK: - Surface / model normalisation (port of normalizeModel + classifySurface)

public enum Surface: String, Sendable {
    case subscription
    case bedrock
    case untracked
}

public enum ModelUtil {
    /// Strip the `[1m]` 1M-context suffix; report whether it was present.
    public static func normalize(_ model: String) -> (base: String, oneM: Bool) {
        if model.hasSuffix("[1m]") {
            return (String(model.dropLast(4)), true)
        }
        return (model, false)
    }

    /// Route a model id to a billing surface — the signal that decides the app's MODE.
    ///  bedrock:      us.anthropic.* / anthropic.*
    ///  subscription: claude-* and bare names (sonnet/opus/haiku)
    ///  untracked:    <synthetic>/<unknown> and anything unrecognised (still counted)
    public static func classifySurface(_ model: String) -> Surface {
        let base = normalize(model).base
        if base.isEmpty || base == "<synthetic>" || base == "<unknown>" { return .untracked }
        if base.hasPrefix("us.anthropic.") || base.hasPrefix("anthropic.") { return .bedrock }
        let lower = base.lowercased()
        if base.hasPrefix("claude-") || lower == "sonnet" || lower == "opus" || lower == "haiku" {
            return .subscription
        }
        return .untracked
    }
}

// MARK: - Aggregate output

/// The current fixed 5-hour rate-limit window (Anthropic-style reset blocks).
public struct WindowStats: Sendable {
    public var active: Bool
    public var tokens: Int
    public var resetAt: Date?      // nil when no active block
    public var blockSeconds: Double
    public var cap: Int            // 0 when no configured cap
    public var calibratedCap: Int  // busiest completed block — informational only

    /// Seconds until reset, or nil when idle.
    public func secondsToReset(now: Date) -> Double? {
        guard let resetAt else { return nil }
        return resetAt.timeIntervalSince(now)
    }

    /// Token %, only when a cap is configured (we never invent a cap → never a guessed %).
    public var tokenPct: Int? {
        guard cap > 0 else { return nil }
        return Int((Double(tokens) / Double(cap) * 100).rounded())
    }

    /// QUOTA remaining as a percent — the headline gauge's only honest "% left". Token-based,
    /// so it exists ONLY when a cap is configured (later: a live server reading). nil means
    /// "no quota basis" — and the UI must then fall back to the time countdown rather than
    /// dress elapsed time up as a usage %. Keeping this token-only is the whole framing fix:
    /// a ring that reads "35% left" must mean 35% of the quota, never 35% of the clock.
    public func quotaLeftPercent() -> Int? {
        guard let used = tokenPct else { return nil }
        return max(0, min(100, 100 - used))
    }

    /// Fraction (0...1) of the window's TIME still left — the honest basis for the countdown
    /// ring when there's no quota %. nil when idle. Deliberately a fraction (not a percent)
    /// and deliberately separate from `quotaLeftPercent` so the two can't be swapped by
    /// accident at a call site.
    public func timeLeftFraction(now: Date) -> Double? {
        guard active, let secs = secondsToReset(now: now), blockSeconds > 0 else { return nil }
        return max(0, min(1, secs / blockSeconds))
    }
}

// MARK: - Live server usage (opt-in) + cap calibration

/// The authoritative server-side rate-limit reading, captured by the opt-in sidecar that
/// runs the official `claude /usage` (the only thing that can know the real %). The app
/// only ever READS this — it never makes the call itself, so the sandbox stays enforced.
/// Every field is optional because `/usage` output drifts; we fail soft to whatever parsed.
public struct LiveUsage: Sendable, Equatable {
    public var sessionPct: Int?
    public var sessionResetText: String?
    public var weeklyPct: Int?
    public var weeklyResetText: String?
    public var weeklyByModel: [String: Int]
    public var capturedAt: Date?

    public init(sessionPct: Int? = nil, sessionResetText: String? = nil,
                weeklyPct: Int? = nil, weeklyResetText: String? = nil,
                weeklyByModel: [String: Int] = [:], capturedAt: Date? = nil) {
        self.sessionPct = sessionPct
        self.sessionResetText = sessionResetText
        self.weeklyPct = weeklyPct
        self.weeklyResetText = weeklyResetText
        self.weeklyByModel = weeklyByModel
        self.capturedAt = capturedAt
    }

    /// Fresh enough to headline as "· live". `/usage` moves slowly, but a reading hours old
    /// must not pose as live — past the TTL we fall back to the calibrated cap (itself
    /// derived from live), so the gauge stays true without lying about freshness. A small
    /// negative age is tolerated for clock skew between the sidecar and the app.
    public func isFresh(now: Date, ttl: TimeInterval = 600) -> Bool {
        guard let capturedAt else { return false }
        let age = now.timeIntervalSince(capturedAt)
        return age >= -60 && age <= ttl
    }
}

/// Derive the 5-hour token cap from a live session-% and our local window token count:
/// cap ≈ tokens / (pct/100). This is how the user "sets a cap" without knowing it — the
/// app learns it from one live reading and keeps showing a real % after live goes away.
///
/// Returns nil when the inputs are too noisy to trust. `sessionPct` is integer-rounded, so
/// the relative error is ≈ 0.5/pct — ~5% at 10%, ~1% at 50%. Below `minPct` we decline
/// rather than persist a wildly off cap from a tiny sample.
public func calibrateCap(windowTokens: Int, sessionPct: Int, minPct: Int = 10) -> Int? {
    guard windowTokens > 0, sessionPct >= minPct else { return nil }
    return Int((Double(windowTokens) / (Double(sessionPct) / 100.0)).rounded())
}

/// Main (direct) vs sub-agent (sidechain) split — the design's "MAIN vs SUB-AGENT".
public struct MainSubSplit: Sendable {
    public var mainTokens: Int = 0
    public var subTokens: Int = 0
    public var mainCost: Double = 0
    public var subCost: Double = 0
    public var total: Int { mainTokens + subTokens }
}

public struct CostSummary: Sendable {
    public var total: Double = 0
    public var today: Double = 0
    public var thisWeek: Double = 0
    public var rolling5h: Double = 0
    public var lastHour: Double = 0
    public var byModel: [String: Double] = [:]
    public var unpricedTokens: Int = 0
    public var unpricedRequests: Int = 0
    public var unpricedModels: [String] = []
}

public struct Aggregate: Sendable {
    public var total = 0
    public var today = 0
    public var thisWeek = 0
    public var rolling5h = 0
    public var lastHourTokens = 0          // for burn rate
    public var byClass = TokenUsage()
    public var bySurface: [Surface: Int] = [:]
    public var byModel: [String: Int] = [:]
    public var split = MainSubSplit()       // all-time main vs sub (+ cost)
    public var todaySplit = MainSubSplit()   // today main vs sub
    public var window = WindowStats(active: false, tokens: 0, resetAt: nil,
                                    blockSeconds: 5 * 3600, cap: 0, calibratedCap: 0)
    public var cost: CostSummary?
    public var counted = 0
    public var duplicatesDropped = 0
    public var approximate = false

    public init() {}

    /// Dominant non-untracked surface → the app's MODE. Mixed machines fall back to
    /// the larger surface (the dropdown still shows the per-surface breakdown).
    public var dominantSurface: Surface {
        var best: Surface = .untracked
        var bestN = -1
        for (s, n) in bySurface where s != .untracked && n > bestN {
            best = s; bestN = n
        }
        return best
    }
}

/// One local calendar day of usage — the unit the History view charts. Carries both
/// tokens and (estimated) dollars plus a per-model breakdown, so the same buckets answer
/// "$ vs tokens" and "busiest model" without a re-read.
public struct DayUsage: Sendable {
    public var date: Date                      // start of this local day
    public var tokens: Int
    public var cost: Double
    public var weekend: Bool
    public var tokensByModel: [String: Int]
    public var costByModel: [String: Double]

    public init(date: Date, tokens: Int = 0, cost: Double = 0, weekend: Bool = false,
                tokensByModel: [String: Int] = [:], costByModel: [String: Double] = [:]) {
        self.date = date
        self.tokens = tokens
        self.cost = cost
        self.weekend = weekend
        self.tokensByModel = tokensByModel
        self.costByModel = costByModel
    }
}

// MARK: - Pricing hook (so Core stays decoupled from the rate table)

public protocol CostModel: Sendable {
    /// Returns (usd, priced). priced == false means "no rate for this model" — the
    /// caller still counts the tokens, it just lands in the unpriced bucket.
    func cost(_ usage: TokenUsage, model: String) -> (usd: Double, priced: Bool)
}

// MARK: - Calendar helpers (LOCAL time — logs are UTC, "today" must mean the user's day)

private func localDayKey(_ d: Date, _ cal: Calendar) -> Int {
    let c = cal.dateComponents([.year, .month, .day], from: d)
    return (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
}

private func startOfLocalWeek(_ now: Date, weekStartsOn: Int, _ cal: Calendar) -> Date {
    let startOfDay = cal.startOfDay(for: now)
    let weekday = cal.component(.weekday, from: startOfDay) // 1 = Sunday
    let zeroBased = weekday - 1
    let diff = (zeroBased - weekStartsOn + 7) % 7
    return cal.date(byAdding: .day, value: -diff, to: startOfDay) ?? startOfDay
}

// MARK: - aggregate()

public struct AggregateOptions: Sendable {
    public var now: Date
    public var weekStartsOn: Int      // 0 = Sunday, 1 = Monday
    public var blockHours: Double
    public var cap: Int               // 0 = none
    public init(now: Date = Date(), weekStartsOn: Int = 1, blockHours: Double = 5, cap: Int = 0) {
        self.now = now
        self.weekStartsOn = weekStartsOn
        self.blockHours = blockHours
        self.cap = cap
    }
}

/// Aggregate a stream of usage records into the snapshot the UI renders.
/// Faithful port of core.mjs `aggregate()`, plus main/sub split, a rolling-1h burn
/// figure, and a cost-injection hook.
public func aggregate(_ records: [UsageRecord],
                      options: AggregateOptions = AggregateOptions(),
                      costModel: CostModel? = nil) -> Aggregate {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current
    let now = options.now
    let nowMs = now.timeIntervalSince1970
    let fiveHours = 5.0 * 3600
    let oneHour = 3600.0
    let todayKey = localDayKey(now, cal)
    let weekStart = startOfLocalWeek(now, weekStartsOn: options.weekStartsOn, cal).timeIntervalSince1970
    let rollingCutoff = nowMs - fiveHours
    let hourCutoff = nowMs - oneHour

    // Pass 1 — dedup, keep-last. Key = messageId:requestId when both exist; otherwise a
    // unique key (a line missing an id is always counted, never collapsed). Streaming
    // emits several usage lines per message sharing a key; output_tokens GROWS across
    // them, so the FINAL line wins.
    var kept: [String: UsageRecord] = [:]
    var order: [String] = []        // preserve first-seen order for determinism
    var uniqueCounter = 0
    var duplicatesDropped = 0
    var approximate = false

    for r in records {
        let hasIds = (r.messageId?.isEmpty == false) && (r.requestId?.isEmpty == false)
        let key: String
        if hasIds {
            key = "\(r.messageId!):\(r.requestId!)"
        } else {
            key = "__nokey__\(uniqueCounter)"
            uniqueCounter += 1
            approximate = true
        }
        if kept[key] != nil {
            duplicatesDropped += 1
        } else {
            order.append(key)
        }
        kept[key] = r // last-write-wins
    }

    // Pass 2 — aggregate the deduped records.
    var agg = Aggregate()
    agg.window.blockSeconds = options.blockHours * 3600
    var costSummary = CostSummary()
    var unpricedModels = Set<String>()
    var stamps: [(t: Double, sum: Int)] = []
    let haveCost = costModel != nil

    for key in order {
        guard let r = kept[key] else { continue }
        let sum = r.usage.sum
        agg.counted += 1
        agg.total += sum
        agg.byClass.input += r.usage.input
        agg.byClass.cacheCreate += r.usage.cacheCreate
        agg.byClass.cacheRead += r.usage.cacheRead
        agg.byClass.output += r.usage.output

        let surface = ModelUtil.classifySurface(r.model)
        agg.bySurface[surface, default: 0] += sum
        let base = ModelUtil.normalize(r.model).base
        agg.byModel[base, default: 0] += sum

        var usd = 0.0
        var priced = false
        if let cm = costModel {
            let c = cm.cost(r.usage, model: r.model)
            usd = c.usd; priced = c.priced
            if priced {
                costSummary.total += usd
                costSummary.byModel[base, default: 0] += usd
            } else {
                costSummary.unpricedTokens += sum
                costSummary.unpricedRequests += 1
                unpricedModels.insert(base)
            }
        }

        // All-time main vs sub split.
        if r.isSidechain {
            agg.split.subTokens += sum
            agg.split.subCost += priced ? usd : 0
        } else {
            agg.split.mainTokens += sum
            agg.split.mainCost += priced ? usd : 0
        }

        if let ts = r.timestamp {
            let tms = ts.timeIntervalSince1970
            // Upper-bound every window at `now` so a future-dated line (clock skew)
            // can't inflate today/week/5h. Total still includes it.
            if tms <= nowMs {
                let dayKey = localDayKey(ts, cal)
                if dayKey == todayKey {
                    agg.today += sum
                    if r.isSidechain { agg.todaySplit.subTokens += sum; agg.todaySplit.subCost += priced ? usd : 0 }
                    else { agg.todaySplit.mainTokens += sum; agg.todaySplit.mainCost += priced ? usd : 0 }
                }
                if tms >= weekStart { agg.thisWeek += sum }
                if tms > rollingCutoff { agg.rolling5h += sum }
                if tms > hourCutoff { agg.lastHourTokens += sum }
                if priced {
                    if dayKey == todayKey { costSummary.today += usd }
                    if tms >= weekStart { costSummary.thisWeek += usd }
                    if tms > rollingCutoff { costSummary.rolling5h += usd }
                    if tms > hourCutoff { costSummary.lastHour += usd }
                }
                stamps.append((tms, sum))
            }
        }
    }

    // Pass 3 — current usage window (fixed blockHours reset blocks, anchored to the
    // first message of the block — verified against Claude's /usage).
    let blockSeconds = options.blockHours * 3600
    stamps.sort { $0.t < $1.t }
    struct Block { var start: Double; var lastT: Double; var tokens: Int }
    var blocks: [Block] = []
    for s in stamps {
        if var last = blocks.last,
           s.t - last.lastT <= blockSeconds,
           s.t < last.start + blockSeconds {
            last.tokens += s.sum
            last.lastT = s.t
            blocks[blocks.count - 1] = last
        } else {
            blocks.append(Block(start: s.t, lastT: s.t, tokens: s.sum))
        }
    }
    let lastBlock = blocks.last
    let windowActive = lastBlock.map { nowMs >= $0.start && nowMs < $0.start + blockSeconds } ?? false
    let completed = windowActive ? Array(blocks.dropLast()) : blocks
    let calibratedCap = completed.reduce(0) { max($0, $1.tokens) }
    agg.window.active = windowActive
    agg.window.tokens = windowActive ? (lastBlock?.tokens ?? 0) : 0
    agg.window.resetAt = windowActive ? Date(timeIntervalSince1970: (lastBlock!.start + blockSeconds)) : nil
    agg.window.cap = options.cap > 0 ? options.cap : 0
    agg.window.calibratedCap = calibratedCap

    agg.duplicatesDropped = duplicatesDropped
    agg.approximate = approximate
    if haveCost {
        costSummary.unpricedModels = unpricedModels.sorted()
        agg.cost = costSummary
    }
    return agg
}

// MARK: - dailyHistory()

/// Bucket usage into a contiguous run of `days` local days ending today — the series the
/// History view charts. Days with no usage are present as zero entries so the chart's day
/// axis is continuous (a gap is an honest empty bar, not a missing column).
///
/// Dedup is the SAME keep-last rule as `aggregate()` (a streaming message's final line wins),
/// reproduced here rather than shared so the audited aggregate path stays untouched. Records
/// without a timestamp can't be placed on a day and are skipped; a future-dated line (clock
/// skew) is upper-bounded out, exactly as the windowed totals are.
public func dailyHistory(_ records: [UsageRecord],
                         days: Int = 60,
                         now: Date = Date(),
                         costModel: CostModel? = nil) -> [DayUsage] {
    guard days > 0 else { return [] }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current
    let nowMs = now.timeIntervalSince1970

    // Pass 1 — dedup, keep-last, first-seen order (mirrors aggregate()).
    var kept: [String: UsageRecord] = [:]
    var order: [String] = []
    var uniqueCounter = 0
    for r in records {
        let hasIds = (r.messageId?.isEmpty == false) && (r.requestId?.isEmpty == false)
        let key: String
        if hasIds {
            key = "\(r.messageId!):\(r.requestId!)"
        } else {
            key = "__nokey__\(uniqueCounter)"
            uniqueCounter += 1
        }
        if kept[key] == nil { order.append(key) }
        kept[key] = r
    }

    // Pass 2 — sum into per-day buckets keyed by local day.
    var tokensByDay: [Int: Int] = [:]
    var costByDay: [Int: Double] = [:]
    var tokModelByDay: [Int: [String: Int]] = [:]
    var costModelByDay: [Int: [String: Double]] = [:]
    for key in order {
        guard let r = kept[key], let ts = r.timestamp else { continue }
        let tms = ts.timeIntervalSince1970
        if tms > nowMs { continue }                       // skip future-dated (clock skew)
        let dk = localDayKey(ts, cal)
        let sum = r.usage.sum
        let base = ModelUtil.normalize(r.model).base
        tokensByDay[dk, default: 0] += sum
        tokModelByDay[dk, default: [:]][base, default: 0] += sum
        if let cm = costModel {
            let c = cm.cost(r.usage, model: r.model)
            if c.priced {
                costByDay[dk, default: 0] += c.usd
                costModelByDay[dk, default: [:]][base, default: 0] += c.usd
            }
        }
    }

    // Pass 3 — emit `days` contiguous days ending today (oldest first), zero-filling gaps.
    let todayStart = cal.startOfDay(for: now)
    var out: [DayUsage] = []
    out.reserveCapacity(days)
    for offset in stride(from: days - 1, through: 0, by: -1) {
        guard let dayStart = cal.date(byAdding: .day, value: -offset, to: todayStart) else { continue }
        let dk = localDayKey(dayStart, cal)
        out.append(DayUsage(date: dayStart,
                            tokens: tokensByDay[dk] ?? 0,
                            cost: costByDay[dk] ?? 0,
                            weekend: cal.isDateInWeekend(dayStart),
                            tokensByModel: tokModelByDay[dk] ?? [:],
                            costByModel: costModelByDay[dk] ?? [:]))
    }
    return out
}
