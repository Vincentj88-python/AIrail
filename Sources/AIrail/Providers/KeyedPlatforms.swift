import Foundation
import SwiftUI

/// The catalog behind "Other…": platforms whose usage or credits API is
/// documented. Each entry is a handful of lines plus a fixture test; the
/// response shapes come from the platforms' own API docs.
extension KeyedPlatform {
    static let catalog: [KeyedPlatform] = [openRouter, deepSeek, anthropicAPI, openAIAPI]

    static let openRouter = KeyedPlatform(
        id: "openrouter",
        displayName: "OpenRouter",
        color: Color(hex: 0x6366F1),
        symbolName: "point.3.connected.trianglepath.dotted",
        keyKind: "API key",
        keyPlaceholder: "sk-or-v1-…",
        keyURL: URL(string: "https://openrouter.ai/settings/keys"),
        connection: ConnectionMethod(
            toolName: "OpenRouter",
            summary: "Credits used and remaining, per key",
            explainer: "AIrail asks OpenRouter what this key has spent against its limit and how many credits the account has left, using OpenRouter's documented key and credits endpoints. The key is stored in your Keychain and sent only to openrouter.ai."
        ),
        fetch: { key, providerId, displayName in
            let headers = ["Authorization": "Bearer \(key)", "Accept": "application/json"]
            let keyData = try await HTTPClient.authorizedGet(URL(string: "https://openrouter.ai/api/v1/auth/key")!, headers: headers, tool: displayName)
            let creditsData = try? await HTTPClient.authorizedGet(URL(string: "https://openrouter.ai/api/v1/credits")!, headers: headers, tool: displayName)
            return try OpenRouterUsage.snapshot(keyData: keyData, creditsData: creditsData, providerId: providerId, displayName: displayName)
        }
    )

    static let deepSeek = KeyedPlatform(
        id: "deepseek",
        displayName: "DeepSeek",
        color: Color(hex: 0x4D6BFE),
        symbolName: "water.waves",
        keyKind: "API key",
        keyPlaceholder: "sk-…",
        keyURL: URL(string: "https://platform.deepseek.com/api_keys"),
        connection: ConnectionMethod(
            toolName: "DeepSeek",
            summary: "Account balance",
            explainer: "AIrail asks DeepSeek for the account's remaining balance using its documented balance endpoint. DeepSeek publishes no usage history, so this account shows the balance only. The key is stored in your Keychain and sent only to api.deepseek.com."
        ),
        fetch: { key, providerId, displayName in
            let headers = ["Authorization": "Bearer \(key)", "Accept": "application/json"]
            let data = try await HTTPClient.authorizedGet(URL(string: "https://api.deepseek.com/user/balance")!, headers: headers, tool: displayName)
            return try DeepSeekUsage.snapshot(data: data, providerId: providerId, displayName: displayName)
        }
    )

    static let anthropicAPI = KeyedPlatform(
        id: "anthropic-api",
        displayName: "Anthropic API",
        color: Color(hex: 0xD97757),
        symbolName: "sparkles",
        brandIconPath: BrandIcons.claude,
        keyKind: "Admin key",
        keyPlaceholder: "sk-ant-admin…",
        keyURL: URL(string: "https://console.anthropic.com/settings/admin-keys"),
        connection: ConnectionMethod(
            toolName: "Anthropic API",
            summary: "Organization usage and cost, by model",
            explainer: "For pay-as-you-go API use (not a Claude subscription). AIrail reads your organization's usage report and cost report with an Admin key — tokens per day and per model for the last 7 days, and this month's spend. The key is stored in your Keychain and sent only to api.anthropic.com.",
            caveat: "Needs an organization Admin key from the Console; a regular API key can't read reports."
        ),
        fetch: { key, providerId, displayName in
            let headers = ["x-api-key": key, "anthropic-version": "2023-06-01", "Accept": "application/json"]
            let now = Date()
            let usageURL = AnthropicAPIUsage.usageURL(now: now)
            let costURL = AnthropicAPIUsage.costURL(now: now)
            let usage = try await HTTPClient.authorizedGet(usageURL, headers: headers, tool: displayName)
            let cost = try? await HTTPClient.authorizedGet(costURL, headers: headers, tool: displayName)
            return try AnthropicAPIUsage.snapshot(usageData: usage, costData: cost, providerId: providerId, displayName: displayName, now: now)
        }
    )

    static let openAIAPI = KeyedPlatform(
        id: "openai-api",
        displayName: "OpenAI API",
        color: Color(hex: 0x10A37F),
        symbolName: "bubble.left.and.bubble.right",
        brandIconPath: BrandIcons.openAI,
        keyKind: "Admin key",
        keyPlaceholder: "sk-admin-…",
        keyURL: URL(string: "https://platform.openai.com/settings/organization/admin-keys"),
        connection: ConnectionMethod(
            toolName: "OpenAI API",
            summary: "Organization usage and cost, by model",
            explainer: "For pay-as-you-go API use (not ChatGPT or Codex). AIrail reads your organization's completions usage and costs with an Admin key — tokens per day and per model for the last 7 days, and this month's spend. The key is stored in your Keychain and sent only to api.openai.com.",
            caveat: "Needs an organization Admin key from the platform settings; a regular API key can't read usage."
        ),
        fetch: { key, providerId, displayName in
            let headers = ["Authorization": "Bearer \(key)", "Accept": "application/json"]
            let now = Date()
            let usage = try await HTTPClient.authorizedGet(OpenAIAPIUsage.usageURL(now: now), headers: headers, tool: displayName)
            let cost = try? await HTTPClient.authorizedGet(OpenAIAPIUsage.costURL(now: now), headers: headers, tool: displayName)
            return try OpenAIAPIUsage.snapshot(usageData: usage, costData: cost, providerId: providerId, displayName: displayName, now: now)
        }
    )
}

// MARK: - OpenRouter

enum OpenRouterUsage {
    /// `/auth/key`: `{"data": {"label", "usage", "usage_monthly", "limit", "limit_remaining",
    /// "limit_reset", "is_free_tier"}}` — `usage` is all time, `usage_monthly` the current UTC
    /// month, `limit_reset` "daily"/"weekly"/"monthly" or null for a limit that never resets;
    /// `/credits`: `{"data": {"total_credits", "total_usage"}}`. All amounts in USD.
    static func snapshot(keyData: Data, creditsData: Data?, providerId: String, displayName: String, now: Date = Date()) throws -> UsageSnapshot {
        guard let key = try JSONObject(data: keyData)["data"] else {
            throw ConnectionError.unreadable("no key data in response")
        }
        let usage = key.double("usage") ?? 0
        let monthly = key.double("usage_monthly")
        let limit = key.double("limit").flatMap { $0 > 0 ? $0 : nil }
        let limitReset = key.string("limit_reset")
        // What OpenRouter itself counts against the key's limit. `usage` is
        // all time and keeps growing across a daily, weekly or monthly reset.
        let againstLimit = limit.map { limit in
            key.double("limit_remaining").map { max(0, limit - $0) } ?? usage
        }
        let credits = creditsData.flatMap { try? JSONObject(data: $0)["data"] }
        let totalCredits = credits?.double("total_credits")
        let totalUsage = credits?.double("total_usage")

        var percent: Double?
        var period = "key limit"
        if let limit, let againstLimit {
            percent = UsageSnapshot.clampPercent(againstLimit / limit * 100)
        } else if let totalCredits, totalCredits > 0, let totalUsage {
            percent = UsageSnapshot.clampPercent(totalUsage / totalCredits * 100)
            period = "credits"
        }
        var snapshot = UsageSnapshot.empty(providerId: providerId, displayName: displayName, status: .ok)
        snapshot.weeklyPercent = percent
        snapshot.periodLabel = period
        // The footer pairs a figure only with a cap measured over the same
        // window: this UTC month for an open key or a monthly budget, the
        // key's own budget when it resets on some other clock or never, and
        // everything ever spent on an answer without `usage_monthly`.
        if let monthly, limit == nil || limitReset == "monthly" {
            snapshot.spend = monthly
            snapshot.spendCap = limit
            snapshot.spendPeriod = .month
        } else if let limit, let againstLimit {
            snapshot.spend = againstLimit
            snapshot.spendCap = limit
            snapshot.spendPeriod = .keyLimit
        } else {
            snapshot.spend = usage
            snapshot.spendPeriod = .lifetime
        }
        if let totalCredits, let totalUsage {
            snapshot.credits = max(0, totalCredits - totalUsage)
            snapshot.creditsCurrency = "USD"
        }
        snapshot.plan = key.bool("is_free_tier") == true ? "Free tier" : nil
        snapshot.account = key.string("label")
        snapshot.lastUpdated = now
        return snapshot
    }
}

// MARK: - DeepSeek

enum DeepSeekUsage {
    /// `{"is_available": true, "balance_infos": [{"currency": "USD", "total_balance": "110.00", …}]}`.
    static func snapshot(data: Data, providerId: String, displayName: String, now: Date = Date()) throws -> UsageSnapshot {
        let json = try JSONObject(data: data)
        let balances = json.array("balance_infos")
        guard let balance = balances.first(where: { $0.string("currency") == "USD" }) ?? balances.first else {
            throw ConnectionError.unreadable("no balance in response")
        }
        var snapshot = UsageSnapshot.empty(providerId: providerId, displayName: displayName, status: .ok)
        snapshot.credits = balance.double("total_balance")
        snapshot.creditsCurrency = balance.string("currency")
        snapshot.plan = json.bool("is_available") == false ? "No balance" : nil
        snapshot.lastUpdated = now
        return snapshot
    }
}

// MARK: - Anthropic API

enum AnthropicAPIUsage {
    private static let base = "https://api.anthropic.com/v1/organizations"

    /// Daily buckets need UTC-midnight boundaries; the window is the last 7 UTC days.
    static func usageURL(now: Date) -> URL {
        let (start, end) = utcDayWindow(days: 7, now: now)
        var components = URLComponents(string: base + "/usage_report/messages")!
        components.queryItems = [
            .init(name: "starting_at", value: iso(start)),
            .init(name: "ending_at", value: iso(end)),
            .init(name: "bucket_width", value: "1d"),
            .init(name: "group_by[]", value: "model"),
            .init(name: "limit", value: "7"),
        ]
        return components.url!
    }

    static func costURL(now: Date) -> URL {
        var components = URLComponents(string: base + "/cost_report")!
        components.queryItems = [
            .init(name: "starting_at", value: iso(utcMonthStart(now: now))),
            .init(name: "ending_at", value: iso(utcDayWindow(days: 1, now: now).1)),
            .init(name: "bucket_width", value: "1d"),
            .init(name: "limit", value: "31"),
        ]
        return components.url!
    }

    /// Usage: `{"data": [{"starting_at", "results": [{"model", "uncached_input_tokens", "output_tokens",
    /// "cache_read_input_tokens", "cache_creation": {"ephemeral_1h_input_tokens", "ephemeral_5m_input_tokens"}}]}]}`.
    /// Cost: `{"data": [{"starting_at", "results": [{"currency": "USD", "amount": "<minor units>"}]}]}`.
    static func snapshot(usageData: Data, costData: Data?, providerId: String, displayName: String, now: Date = Date()) throws -> UsageSnapshot {
        let usage = try JSONObject(data: usageData)
        var days: [Date: UsageAggregate] = [:]
        var week = UsageAggregate()
        let calendar = Calendar.current
        for bucket in usage.array("data") {
            guard let start = DateParsing.iso8601(bucket.string("starting_at")) else { continue }
            let day = calendar.startOfDay(for: start.addingTimeInterval(1))
            for result in bucket.array("results") {
                var aggregate = UsageAggregate()
                let cache = result["cache_creation"]
                aggregate.tokens = TokenSplit(
                    input: result.double("uncached_input_tokens") ?? 0,
                    output: result.double("output_tokens") ?? 0,
                    cacheWrite: (cache?.double("ephemeral_1h_input_tokens") ?? 0) + (cache?.double("ephemeral_5m_input_tokens") ?? 0),
                    cacheRead: result.double("cache_read_input_tokens") ?? 0
                )
                if let model = result.string("model"), aggregate.tokens.total > 0 {
                    aggregate.models[model] = aggregate.tokens.total
                }
                days[day, default: UsageAggregate()].merge(aggregate)
                week.merge(aggregate)
            }
        }
        var spend: Double?
        if let costData, let cost = try? JSONObject(data: costData) {
            var cents = 0.0
            for bucket in cost.array("data") {
                for result in bucket.array("results") {
                    cents += result.double("amount") ?? 0
                }
            }
            spend = cents / 100
        }
        var snapshot = UsageSnapshot.empty(providerId: providerId, displayName: displayName, status: .ok)
        snapshot.spend = spend
        snapshot.periodLabel = "month"
        snapshot.plan = "Pay as you go"
        snapshot.lastUpdated = now
        let series = UsageBucketing.series(days, count: 7, component: .day, endingAt: now, calendar: calendar)
        snapshot.detail = UsageDetail(days: series, week: week)
        return snapshot
    }

    // MARK: Time helpers (shared with OpenAI)

    static func utcDayWindow(days: Int, now: Date) -> (Date, Date) {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let today = utc.startOfDay(for: now)
        let end = utc.date(byAdding: .day, value: 1, to: today)!
        let start = utc.date(byAdding: .day, value: -(days - 1), to: today)!
        return (start, end)
    }

    static func utcMonthStart(now: Date) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.dateInterval(of: .month, for: now)?.start ?? now
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

// MARK: - OpenAI API

enum OpenAIAPIUsage {
    private static let base = "https://api.openai.com/v1/organization"

    static func usageURL(now: Date) -> URL {
        let (start, end) = AnthropicAPIUsage.utcDayWindow(days: 7, now: now)
        var components = URLComponents(string: base + "/usage/completions")!
        components.queryItems = [
            .init(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
            .init(name: "end_time", value: String(Int(end.timeIntervalSince1970))),
            .init(name: "bucket_width", value: "1d"),
            .init(name: "group_by", value: "model"),
            .init(name: "limit", value: "7"),
        ]
        return components.url!
    }

    static func costURL(now: Date) -> URL {
        var components = URLComponents(string: base + "/costs")!
        components.queryItems = [
            .init(name: "start_time", value: String(Int(AnthropicAPIUsage.utcMonthStart(now: now).timeIntervalSince1970))),
            .init(name: "bucket_width", value: "1d"),
            .init(name: "limit", value: "31"),
        ]
        return components.url!
    }

    /// Usage: `{"data": [{"start_time", "results": [{"model", "input_tokens", "output_tokens",
    /// "input_cached_tokens", "num_model_requests"}]}]}`.
    /// Costs: `{"data": [{"start_time", "results": [{"amount": {"value": 0.06, "currency": "usd"}}]}]}`.
    static func snapshot(usageData: Data, costData: Data?, providerId: String, displayName: String, now: Date = Date()) throws -> UsageSnapshot {
        let usage = try JSONObject(data: usageData)
        var days: [Date: UsageAggregate] = [:]
        var week = UsageAggregate()
        let calendar = Calendar.current
        for bucket in usage.array("data") {
            guard let start = DateParsing.unixSeconds(bucket.double("start_time")) else { continue }
            let day = calendar.startOfDay(for: start.addingTimeInterval(1))
            for result in bucket.array("results") {
                var aggregate = UsageAggregate()
                let input = result.double("input_tokens") ?? 0
                let cached = result.double("input_cached_tokens") ?? 0
                aggregate.tokens = TokenSplit(
                    input: max(0, input - cached),
                    output: result.double("output_tokens") ?? 0,
                    cacheRead: cached
                )
                aggregate.messages = Int(result.double("num_model_requests") ?? 0)
                if let model = result.string("model"), aggregate.tokens.total > 0 {
                    aggregate.models[model] = aggregate.tokens.total
                }
                days[day, default: UsageAggregate()].merge(aggregate)
                week.merge(aggregate)
            }
        }
        var spend: Double?
        if let costData, let cost = try? JSONObject(data: costData) {
            var dollars = 0.0
            for bucket in cost.array("data") {
                for result in bucket.array("results") {
                    dollars += result["amount"]?.double("value") ?? 0
                }
            }
            spend = dollars
        }
        var snapshot = UsageSnapshot.empty(providerId: providerId, displayName: displayName, status: .ok)
        snapshot.spend = spend
        snapshot.periodLabel = "month"
        snapshot.plan = "Pay as you go"
        snapshot.lastUpdated = now
        let series = UsageBucketing.series(days, count: 7, component: .day, endingAt: now, calendar: calendar)
        snapshot.detail = UsageDetail(days: series, week: week)
        return snapshot
    }
}
