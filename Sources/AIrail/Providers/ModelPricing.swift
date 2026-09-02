import Foundation

/// Public per-token API prices, USD per 1M tokens, used only for the
/// "what would this have cost on the API?" estimate. Approximate and easy to
/// edit — always shown to the user as an estimate, never as a bill.
struct TokenPrices: Sendable {
    var input: Double
    var output: Double
    var cacheWrite: Double
    var cacheRead: Double
}

enum ModelPricing {
    /// Prices matched by a prefix of the model id (lowercased). First match wins;
    /// order most-specific first. The final entry is the catch-all.
    private static let table: [(prefix: String, prices: TokenPrices)] = [
        ("claude-opus",   TokenPrices(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5)),
        ("claude-sonnet", TokenPrices(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3)),
        ("claude-haiku",  TokenPrices(input: 0.8, output: 4, cacheWrite: 1.0, cacheRead: 0.08)),
        ("claude-fable",  TokenPrices(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5)),
        ("claude",        TokenPrices(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5)),
        ("gpt-5",         TokenPrices(input: 2.5, output: 10, cacheWrite: 2.5, cacheRead: 0.25)),
        ("gpt",           TokenPrices(input: 2.5, output: 10, cacheWrite: 2.5, cacheRead: 0.25)),
        ("o3",            TokenPrices(input: 10, output: 40, cacheWrite: 10, cacheRead: 2.5)),
        ("gemini",        TokenPrices(input: 2.5, output: 10, cacheWrite: 2.5, cacheRead: 0.25)),
        ("grok",          TokenPrices(input: 3, output: 15, cacheWrite: 3, cacheRead: 0.3)),
    ]
    private static let fallback = TokenPrices(input: 4, output: 16, cacheWrite: 5, cacheRead: 0.4)

    static func prices(for model: String?) -> TokenPrices {
        guard let model = model?.lowercased() else { return fallback }
        return table.first { model.hasPrefix($0.prefix) }?.prices ?? fallback
    }

    /// API-equivalent USD for a week's tokens, priced at the dominant model's
    /// rate. Cache reads are the bulk of the volume and the cheapest, so this
    /// lands far below a naive input-rate estimate. Nil when there's nothing to price.
    static func estimate(_ week: UsageAggregate) -> Double? {
        let tokens = week.tokens
        guard tokens.total > 0 else { return nil }
        let dominant = week.models.max { $0.value < $1.value }?.key
        let p = prices(for: dominant)
        let dollars =
            tokens.input * p.input +
            tokens.output * p.output +
            tokens.cacheWrite * p.cacheWrite +
            tokens.cacheRead * p.cacheRead
        return dollars / 1_000_000
    }
}
