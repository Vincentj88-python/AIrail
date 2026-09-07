import Foundation

/// Per-token API prices, USD per 1M tokens, for the "what would this have cost
/// on the API?" estimate. Always shown to the user as an estimate.
struct TokenPrices: Sendable, Equatable {
    var input: Double
    var output: Double
    var cacheWrite: Double
    var cacheRead: Double

    /// USD for `tokens` at these rates.
    func cost(of tokens: TokenSplit) -> Double {
        (tokens.input * input + tokens.output * output
            + tokens.cacheWrite * cacheWrite + tokens.cacheRead * cacheRead) / 1_000_000
    }

    /// A mid-range rate for ids the table doesn't know, so an unfamiliar model
    /// still counts toward the (labelled) estimate instead of vanishing from it.
    static let unlisted = TokenPrices(input: 4, output: 16, cacheWrite: 5, cacheRead: 0.4)
}

/// A shipped price table — nothing is fetched. Checked by hand against the
/// vendors' price pages at each release (see README › Releasing); the update
/// checker is what carries corrected prices to users.
enum ModelPricing {
    /// Public list prices, USD per 1M tokens: input / output / cache write /
    /// cache read. Keys are fragments of a normalized id (`normalize`) that
    /// must sit at a boundary — preceded by the start or "-", followed by the
    /// end, "-" or "." — so "opus-4.1" fits "claude-opus-4.1.20250805" and
    /// "gpt-5" fits both "gpt-5.5-mini" and "cursor-gpt-5-high", but "gpt" never
    /// fits "chatgpt-4o-latest". The longest fitting key wins, which is how a
    /// version with its own price beats its family row. Only Anthropic charges
    /// extra to write the cache; elsewhere a cache write is an ordinary input token.
    /// Checked 2026-09-06.
    static let table: [(key: String, prices: TokenPrices)] = [
        // Anthropic — family words, since ids read both "claude-opus-4-8" and
        // "claude-3-5-haiku-…". Opus 4 (dated id, "opus-4.0" and the
        // version-first "claude-4-opus" spellings) and 4.1 were 3× today's Opus.
        ("opus-4.20250514", TokenPrices(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5)),
        ("opus-4.0", TokenPrices(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5)),
        ("4-opus", TokenPrices(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5)),
        ("opus-4.1", TokenPrices(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5)),
        ("4.1-opus", TokenPrices(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5)),
        ("opus", TokenPrices(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5)),
        ("sonnet", TokenPrices(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3)),
        ("haiku", TokenPrices(input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.1)),
        ("fable", TokenPrices(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5)),
        // OpenAI — "gpt-5" also covers 5.1, the codex variants and any 5.x
        // without a row of its own; the mini/pro variants need their own rows
        // or they would price at the family rate.
        ("gpt-5.2", TokenPrices(input: 1.75, output: 14, cacheWrite: 1.75, cacheRead: 0.175)),
        ("gpt-5-mini", TokenPrices(input: 0.25, output: 2, cacheWrite: 0.25, cacheRead: 0.025)),
        ("gpt-5-nano", TokenPrices(input: 0.05, output: 0.4, cacheWrite: 0.05, cacheRead: 0.005)),
        ("gpt-5", TokenPrices(input: 1.25, output: 10, cacheWrite: 1.25, cacheRead: 0.125)),
        ("gpt-4.1-mini", TokenPrices(input: 0.4, output: 1.6, cacheWrite: 0.4, cacheRead: 0.1)),
        ("gpt-4.1", TokenPrices(input: 2, output: 8, cacheWrite: 2, cacheRead: 0.5)),
        ("gpt-4o-mini", TokenPrices(input: 0.15, output: 0.6, cacheWrite: 0.15, cacheRead: 0.075)),
        ("gpt-4o", TokenPrices(input: 2.5, output: 10, cacheWrite: 2.5, cacheRead: 1.25)),
        ("o3-mini", TokenPrices(input: 1.1, output: 4.4, cacheWrite: 1.1, cacheRead: 0.55)),
        ("o3-pro", TokenPrices(input: 20, output: 80, cacheWrite: 20, cacheRead: 5)),
        ("o3", TokenPrices(input: 2, output: 8, cacheWrite: 2, cacheRead: 0.5)),
        ("o4-mini", TokenPrices(input: 1.1, output: 4.4, cacheWrite: 1.1, cacheRead: 0.275)),
        ("gpt", TokenPrices(input: 1.25, output: 10, cacheWrite: 1.25, cacheRead: 0.125)),
        // Google — the family row is Gemini 3 Pro.
        ("gemini-2.5-pro", TokenPrices(input: 1.25, output: 10, cacheWrite: 1.25, cacheRead: 0.31)),
        ("gemini-2.5-flash", TokenPrices(input: 0.3, output: 2.5, cacheWrite: 0.3, cacheRead: 0.03)),
        ("gemini-3-flash", TokenPrices(input: 0.5, output: 3, cacheWrite: 0.5, cacheRead: 0.05)),
        ("gemini", TokenPrices(input: 2, output: 12, cacheWrite: 2, cacheRead: 0.2)),
        // xAI — the family row is Grok 4.
        ("grok-4-fast", TokenPrices(input: 0.2, output: 0.5, cacheWrite: 0.2, cacheRead: 0.05)),
        ("grok-code-fast", TokenPrices(input: 0.2, output: 1.5, cacheWrite: 0.2, cacheRead: 0.02)),
        ("grok", TokenPrices(input: 3, output: 15, cacheWrite: 3, cacheRead: 0.75)),
    ]

    // MARK: Lookup

    /// The table's rate for a model id: the longest key that fits, else `unlisted`.
    static func prices(for model: String) -> TokenPrices {
        let id = normalize(model)
        var best: (key: String, prices: TokenPrices)?
        for row in table where row.key.count > (best?.key.count ?? 0) && fits(row.key, in: id) {
            best = row
        }
        return best?.prices ?? .unlisted
    }

    /// API-equivalent USD for a week's tokens: the week's input/output/cache
    /// mix priced per model, each model weighted by its share of the week's
    /// tokens (the mix itself is only known for the week as a whole). Nil for
    /// a week without tokens.
    static func estimate(_ week: UsageAggregate) -> Double? {
        let tokens = week.tokens
        guard tokens.total > 0 else { return nil }
        let shares = week.models.filter { $0.value > 0 }
        let counted = shares.values.reduce(0, +)
        guard counted > 0 else { return TokenPrices.unlisted.cost(of: tokens) }
        return shares.reduce(0) { dollars, share in
            dollars + prices(for: share.key).cost(of: tokens) * share.value / counted
        }
    }

    /// Model ids from vendors ("anthropic/claude-opus-4.8:batch") and from
    /// transcripts ("claude-opus-4-8") to a common key ("claude-opus-4.8").
    static func normalize(_ id: String) -> String {
        var s = id.lowercased()
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        // Version digits split by dashes become dots: "opus-4-8" → "opus-4.8".
        var out = ""
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            if c == "-", i > 0, i < chars.count - 1, chars[i-1].isNumber, chars[i+1].isNumber {
                out.append(".")
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// `key` somewhere in `id` at a boundary on both sides (see `table`).
    private static func fits(_ key: String, in id: String) -> Bool {
        var from = id.startIndex
        while let range = id.range(of: key, range: from..<id.endIndex) {
            let openBefore = range.lowerBound == id.startIndex || id[id.index(before: range.lowerBound)] == "-"
            let openAfter = range.upperBound == id.endIndex || "-.".contains(id[range.upperBound])
            if openBefore && openAfter { return true }
            from = id.index(after: range.lowerBound)
        }
        return false
    }
}
