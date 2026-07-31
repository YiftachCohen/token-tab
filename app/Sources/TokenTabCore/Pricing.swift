// Token Tab — price table + cost math (Swift port of ../../src/pricing.mjs).
//
// Dollars are an ESTIMATE, not an invoice. A bundled per-model rate table applied to the
// four token classes the logs already carry — no network call, no key, just arithmetic.
// Rates are USD per MILLION tokens. Input and output are per model; the two cache classes
// are derived from the input rate using PER-PROVIDER multipliers (cache economics differ
// between vendors — see `cacheMultipliers` below):
//   Claude: write = 1.25× input (5-minute-TTL cache write), read = 0.10× input.
//   Codex (OpenAI): write = 0 (no separate cache-write billing step), read = 0.10× input.
//
// Unknown models are NEVER invented a price for: `cost` returns priced:false and the
// caller still counts the tokens. A guessed figure that disagrees with the real bill is
// worse than an honest "no rate."

import Foundation

public struct Pricing: CostModel {
    public init() {}

    private struct CacheMult { let write: Double; let read: Double }

    // Per-provider cache multipliers, relative to each model's own input rate (design
    // doc section 3). Mirrors CACHE_MULTIPLIERS in pricing.mjs.
    private static let cacheMultipliers: [String: CacheMult] = [
        "claude": CacheMult(write: 1.25, read: 0.10),
        "codex": CacheMult(write: 0, read: 0.10),
    ]

    private struct Rate { let input: Double; let output: Double }

    // input / output USD per 1M tokens (Anthropic list pricing). Mirrors RATES in pricing.mjs.
    private static let rates: [String: Rate] = [
        // Current models.
        "claude-fable-5": Rate(input: 10, output: 50),
        "claude-opus-5": Rate(input: 5, output: 25),
        "claude-opus-4-8": Rate(input: 5, output: 25),
        "claude-opus-4-7": Rate(input: 5, output: 25),
        "claude-opus-4-6": Rate(input: 5, output: 25),
        // Sonnet 5 list price. Anthropic is running a $2/$10 introductory rate through
        // 2026-08-31, but the table isn't date-aware and documents itself as list pricing —
        // the intro discount would silently go stale on 2026-09-01. (Same as Sonnet 4.6.)
        "claude-sonnet-5": Rate(input: 3, output: 15),
        "claude-sonnet-4-6": Rate(input: 3, output: 15),
        "claude-haiku-4-5": Rate(input: 1, output: 5),
        // Older, still-billable models.
        "claude-opus-4-5": Rate(input: 5, output: 25),
        "claude-opus-4-1": Rate(input: 15, output: 75),
        "claude-opus-4": Rate(input: 15, output: 75),
        "claude-sonnet-4-5": Rate(input: 3, output: 15),
        "claude-sonnet-4": Rate(input: 3, output: 15),
        "claude-3-5-haiku": Rate(input: 0.8, output: 4),
    ]

    private static let aliases: [String: String] = [
        "opus": "claude-opus-5",
        "sonnet": "claude-sonnet-5",
        "haiku": "claude-haiku-4-5",
    ]

    // ---------------------------------------------------------------------------
    // OpenAI (Codex) rate table — kept in its own map so the Claude table above stays
    // visually intact. Entries VERIFIED 2026-07-31 against OpenAI's per-model API docs
    // pages (standard tier). Mirrors OPENAI_RATES in pricing.mjs.
    //
    // The GPT-5.6 family (Sol/Terra/Luna) went GA in Codex on 2026-07-09 and is now the bulk
    // of Codex traffic, so its absence here was not an edge case — it was most of the bill.
    // NOTE for the next update: Terra and Luna were REPRICED DOWN on 2026-07-30 (terra
    // $2.50/$15 -> $2.00/$12, luna $1.00/$6 -> $0.20/$1.20); most third-party pricing pages
    // still quote the launch rates.
    //
    // Cached input is 0.10x input for every entry here, which cacheMultipliers(codex) already
    // encodes. Long-context (>272K input) surcharges are NOT modeled, consistent with the rest
    // of the table.
    //
    // Deliberately absent (NO published rate we could verify — never guess): gpt-5.3-codex-spark
    // (research preview, "credit rates not final"), gpt-5.4-codex (no such published model),
    // codex-auto-review (internal Codex slug), <codex-unknown>. gpt-5.4-pro/gpt-5.5-pro are
    // absent for a different reason — they're priced, but they aren't Codex CLI models.
    // NO entry → the caller's existing unpriced bucket.
    private static let openAIRates: [String: Rate] = [
        "gpt-5.6-sol": Rate(input: 5.0, output: 30.0),
        "gpt-5.6-terra": Rate(input: 2.0, output: 12.0),
        "gpt-5.6-luna": Rate(input: 0.2, output: 1.2),
        "gpt-5.5": Rate(input: 5.0, output: 30.0),
        "gpt-5.4": Rate(input: 2.5, output: 15.0),
        "gpt-5.4-mini": Rate(input: 0.75, output: 4.5),
        "gpt-5.4-nano": Rate(input: 0.2, output: 1.25),
        "gpt-5.3-codex": Rate(input: 1.75, output: 14.0),
        "gpt-5.2-codex": Rate(input: 1.75, output: 14.0),
        "gpt-5.1-codex": Rate(input: 1.25, output: 10.0),
        "gpt-5.1-codex-max": Rate(input: 1.25, output: 10.0),
        "gpt-5-codex": Rate(input: 1.25, output: 10.0),
    ]

    private static let openAIAliases: [String: String] = [:]

    private static func rates(for provider: String) -> [String: Rate] {
        provider == "codex" ? openAIRates : rates
    }
    private static func aliases(for provider: String) -> [String: String] {
        provider == "codex" ? openAIAliases : aliases
    }

    /// The rate-table's model keys, exposed so tests can assert the shared parity
    /// fixture covers the table exhaustively (see RatesCoverageTests). Claude-only by
    /// default for back-compat; pass a provider to get that provider's keys.
    public static func ratedModelIds(provider: String = "claude") -> Set<String> {
        Set(rates(for: provider).keys)
    }
    public static func aliasIds(provider: String = "claude") -> Set<String> {
        Set(aliases(for: provider).keys)
    }
    // Back-compat computed properties (Claude table).
    public static var ratedModelIds: Set<String> { ratedModelIds(provider: "claude") }
    public static var aliasIds: Set<String> { aliasIds(provider: "claude") }
    // Codex-side equivalent, for the (provider, model)-keyed coverage test.
    public static var openAIRatedModelIds: Set<String> { ratedModelIds(provider: "codex") }

    /// Reduce any model id to the rate-table key.
    /// Claude: strip [1m], Bedrock region/vendor prefixes, the `-vN:M` Bedrock version
    /// suffix, and a trailing `-YYYYMMDD` date. Codex: OpenAI ids are already clean —
    /// just lowercase, no prefix/suffix stripping.
    public static func canonicalModelId(_ model: String, provider: String = "claude") -> String {
        var id = ModelUtil.normalize(model).base.lowercased()
        if provider == "codex" { return id } // OpenAI ids need no further normalization
        for prefix in ["us.", "eu.", "apac.", "us-gov."] where id.hasPrefix(prefix) {
            id = String(id.dropFirst(prefix.count)); break
        }
        if id.hasPrefix("anthropic.") { id = String(id.dropFirst("anthropic.".count)) }
        id = id.replacingOccurrences(of: #"-v\d+:\d+$"#, with: "", options: .regularExpression)
        id = id.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        return id
    }

    private struct ClassRates { let input, cacheWrite, cacheRead, output: Double }

    private static func ratesFor(_ model: String, provider: String) -> ClassRates? {
        let id = canonicalModelId(model, provider: provider)
        let rateTable = rates(for: provider)
        let aliasTable = aliases(for: provider)
        let base = rateTable[id] ?? aliasTable[id].flatMap { rateTable[$0] }
        guard let base else { return nil }
        let mult = cacheMultipliers[provider] ?? cacheMultipliers["claude"]!
        return ClassRates(input: base.input,
                          cacheWrite: base.input * mult.write,
                          cacheRead: base.input * mult.read,
                          output: base.output)
    }

    /// `provider` selects the canonicalizer + rate table + cache multipliers (default
    /// "claude", matching aggregate()'s "absent provider ⇒ claude" convention).
    public func cost(_ usage: TokenUsage, model: String, provider: String = "claude") -> (usd: Double, priced: Bool) {
        guard let r = Pricing.ratesFor(model, provider: provider) else { return (0, false) }
        let usd = (Double(usage.input) * r.input
                   + Double(usage.cacheCreate) * r.cacheWrite
                   + Double(usage.cacheRead) * r.cacheRead
                   + Double(usage.output) * r.output) / 1_000_000
        return (usd, true)
    }
}
