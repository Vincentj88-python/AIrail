import Foundation

/// Per-token API prices, USD per 1M tokens, for the "what would this have cost
/// on the API?" estimate. Live prices come from OpenRouter's public model
/// catalogue (no auth, current, includes cache read/write); a small built-in
/// table is the offline fallback. Always shown to the user as an estimate.
struct TokenPrices: Sendable, Codable {
    var input: Double
    var output: Double
    var cacheWrite: Double
    var cacheRead: Double
}

@MainActor
enum ModelPricing {
    private static let modelsURL = URL(string: "https://openrouter.ai/api/v1/models")!
    private static let cacheKey = "modelPricesCache"
    private static let cacheDateKey = "modelPricesCacheDate"
    private static let refreshInterval: TimeInterval = 7 * 24 * 3600

    /// Live prices keyed by normalized model id (e.g. "claude-opus-4.8").
    private static var fetched: [String: TokenPrices] = loadCache()

    // MARK: Lookup

    static func prices(for model: String?) -> TokenPrices {
        guard let model else { return fallback(for: nil) }
        let key = normalize(model)
        if let exact = fetched[key] { return exact }
        // Nearest by shared prefix (longest match wins) — handles "-mini"/date
        // suffixes not in the catalogue.
        let near = fetched
            .filter { key.hasPrefix($0.key) || $0.key.hasPrefix(key) }
            .max { $0.key.count < $1.key.count }
        return near?.value ?? fallback(for: model)
    }

    /// API-equivalent USD for a week's tokens, at the dominant model's rate.
    static func estimate(_ week: UsageAggregate) -> Double? {
        let tokens = week.tokens
        guard tokens.total > 0 else { return nil }
        let dominant = week.models.max { $0.value < $1.value }?.key
        let p = prices(for: dominant)
        let dollars = tokens.input * p.input + tokens.output * p.output
            + tokens.cacheWrite * p.cacheWrite + tokens.cacheRead * p.cacheRead
        return dollars / 1_000_000
    }

    /// Model ids from OpenRouter ("anthropic/claude-opus-4.8") and from
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

    // MARK: Refresh

    /// Refresh the live table from OpenRouter, at most weekly. Safe to call on launch.
    static func refreshIfDue() {
        let last = UserDefaults.standard.object(forKey: cacheDateKey) as? Date
        if let last, Date().timeIntervalSince(last) < refreshInterval, !fetched.isEmpty { return }
        Task { await refresh() }
    }

    static func refresh() async {
        guard let (data, response) = try? await URLSession.shared.data(from: modelsURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]]
        else { return }

        var table: [String: TokenPrices] = [:]
        for model in models {
            guard let id = model["id"] as? String, !id.contains(":"),
                  let pricing = model["pricing"] as? [String: Any] else { continue }
            func rate(_ key: String) -> Double { Double(pricing[key] as? String ?? "") ?? 0 }
            let prompt = rate("prompt")
            guard prompt > 0 else { continue } // skip free/unpriced entries
            let perM = 1_000_000.0
            table[normalize(id)] = TokenPrices(
                input: prompt * perM,
                output: rate("completion") * perM,
                cacheWrite: (pricing["input_cache_write"] != nil ? rate("input_cache_write") : prompt * 1.25) * perM,
                cacheRead: (pricing["input_cache_read"] != nil ? rate("input_cache_read") : prompt * 0.1) * perM
            )
        }
        guard !table.isEmpty else { return }
        fetched = table
        if let encoded = try? JSONEncoder().encode(table) {
            UserDefaults.standard.set(encoded, forKey: cacheKey)
            UserDefaults.standard.set(Date(), forKey: cacheDateKey)
        }
    }

    private static func loadCache() -> [String: TokenPrices] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let table = try? JSONDecoder().decode([String: TokenPrices].self, from: data)
        else { return [:] }
        return table
    }

    // MARK: Fallback table (offline / unmatched)

    private static let fallbackTable: [(String, TokenPrices)] = [
        ("claude-opus", TokenPrices(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5)),
        ("claude-sonnet", TokenPrices(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3)),
        ("claude-fable", TokenPrices(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5)),
        ("claude", TokenPrices(input: 4, output: 20, cacheWrite: 5, cacheRead: 0.4)),
        ("gpt", TokenPrices(input: 5, output: 30, cacheWrite: 6.25, cacheRead: 0.5)),
        ("gemini", TokenPrices(input: 2.5, output: 10, cacheWrite: 3, cacheRead: 0.25)),
        ("grok", TokenPrices(input: 3, output: 15, cacheWrite: 3, cacheRead: 0.3)),
    ]

    private static func fallback(for model: String?) -> TokenPrices {
        let key = model.map(normalize) ?? ""
        return fallbackTable.first { key.hasPrefix($0.0) }?.1
            ?? TokenPrices(input: 4, output: 16, cacheWrite: 5, cacheRead: 0.4)
    }
}
