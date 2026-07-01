// Token Tab — price table + cost math (Swift port of ../../src/pricing.mjs).
//
// Dollars are an ESTIMATE, not an invoice. A bundled per-model rate table applied to the
// four token classes the logs already carry — no network call, no key, just arithmetic.
// Rates are USD per MILLION tokens, from Anthropic's public list pricing. Input and
// output are per model; the two cache classes are derived from the input rate by
// Anthropic's published multipliers (write = 1.25× input, read = 0.10× input).
//
// Unknown models are NEVER invented a price for: `cost` returns priced:false and the
// caller still counts the tokens. A guessed figure that disagrees with the real bill is
// worse than an honest "no rate."

import Foundation

public struct Pricing: CostModel {
    public init() {}

    private static let cacheWriteMult = 1.25
    private static let cacheReadMult = 0.10

    private struct Rate { let input: Double; let output: Double }

    // input / output USD per 1M tokens (Anthropic list pricing). Mirrors RATES in pricing.mjs.
    private static let rates: [String: Rate] = [
        // Current models.
        "claude-fable-5": Rate(input: 10, output: 50),
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
        "opus": "claude-opus-4-8",
        "sonnet": "claude-sonnet-5",
        "haiku": "claude-haiku-4-5",
    ]

    /// Reduce any model id to the rate-table key (strip [1m], Bedrock region/vendor
    /// prefixes, the `-vN:M` Bedrock version suffix, and a trailing `-YYYYMMDD` date).
    public static func canonicalModelId(_ model: String) -> String {
        var id = ModelUtil.normalize(model).base.lowercased()
        for prefix in ["us.", "eu.", "apac.", "us-gov."] where id.hasPrefix(prefix) {
            id = String(id.dropFirst(prefix.count)); break
        }
        if id.hasPrefix("anthropic.") { id = String(id.dropFirst("anthropic.".count)) }
        id = id.replacingOccurrences(of: #"-v\d+:\d+$"#, with: "", options: .regularExpression)
        id = id.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        return id
    }

    private struct ClassRates { let input, cacheWrite, cacheRead, output: Double }

    private static func ratesFor(_ model: String) -> ClassRates? {
        let id = canonicalModelId(model)
        let base = rates[id] ?? aliases[id].flatMap { rates[$0] }
        guard let base else { return nil }
        return ClassRates(input: base.input,
                          cacheWrite: base.input * cacheWriteMult,
                          cacheRead: base.input * cacheReadMult,
                          output: base.output)
    }

    public func cost(_ usage: TokenUsage, model: String) -> (usd: Double, priced: Bool) {
        guard let r = Pricing.ratesFor(model) else { return (0, false) }
        let usd = (Double(usage.input) * r.input
                   + Double(usage.cacheCreate) * r.cacheWrite
                   + Double(usage.cacheRead) * r.cacheRead
                   + Double(usage.output) * r.output) / 1_000_000
        return (usd, true)
    }
}
