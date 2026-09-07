import Foundation

enum UsageStatus: String, Sendable {
    case ok, demo, stale, error

    /// The word shown on the status pill. `ok` reads as "live" to a human.
    var label: String {
        self == .ok ? "live" : rawValue
    }
}

/// The window a snapshot's `spend` covers, so the footer can name it: a
/// calendar month, the plan's billing cycle, everything the account ever
/// spent, or what an API key has used of its own limit.
enum SpendPeriod: String, Sendable {
    case month, billingCycle, lifetime, keyLimit
}

struct UsageSnapshot: Identifiable, Sendable {
    var id: String { providerId }
    var providerId: String
    var displayName: String
    var sessionPercent: Double?   // 0...100
    var weeklyUsed: Double?
    var weeklyLimit: Double?
    var weeklyPercent: Double?
    var resetsAt: Date?
    var credits: Double?
    /// ISO currency code when `credits` is money rather than a count.
    var creditsCurrency: String? = nil
    var spend: Double?
    var spendCap: Double?
    /// What `spend` (and `spendCap`, when there is one) is measured over.
    var spendPeriod: SpendPeriod = .month
    var plan: String?
    var status: UsageStatus
    var lastUpdated: Date
    /// What the "weekly" numbers actually cover for this provider: some meter
    /// a calendar month or a billing cycle instead of a rolling week.
    var periodLabel: String = "weekly"
    /// What `weeklyUsed` counts: "requests" for most plans, "AI credits" for
    /// Copilot's credits-billed ones. Read as "\(periodLabel) \(unitLabel)".
    var unitLabel: String = "requests"
    /// When the longer window resets, if the provider reports it separately.
    var weeklyResetsAt: Date? = nil
    /// Who is signed in (an email or handle), when the source reveals it.
    var account: String? = nil
    /// Hourly/daily buckets, model and project shares, meters — whatever the
    /// source exposes beyond the headline numbers.
    var detail = UsageDetail()
}

extension UsageSnapshot {
    static func clampPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    /// Percent of `used` against `limit`, clamped to 0...100. Nil when the limit is missing or zero.
    static func percent(used: Double?, limit: Double?) -> Double? {
        guard let used, let limit, limit > 0 else { return nil }
        return clampPercent(used / limit * 100)
    }

    /// The percent driving the rail ring: session if known, else weekly.
    var ringPercent: Double? {
        (sessionPercent ?? weeklyPercent).map(Self.clampPercent)
    }

    /// When the window behind `ringPercent` resets, if the provider says.
    var ringResetsAt: Date? {
        sessionPercent != nil ? resetsAt : (weeklyResetsAt ?? resetsAt)
    }

    /// That window the way the text names it: "session", or the period label.
    var ringWindowLabel: String {
        sessionPercent != nil ? "session" : periodLabel
    }

    /// The same numbers, re-labelled — used to keep the last real reading on
    /// screen (as `stale`) when a refresh fails.
    func marking(_ status: UsageStatus) -> UsageSnapshot {
        var copy = self
        copy.status = status
        return copy
    }

    /// A snapshot with no numbers at all, for a provider that has never been read.
    static func empty(providerId: String, displayName: String, status: UsageStatus) -> UsageSnapshot {
        UsageSnapshot(
            providerId: providerId,
            displayName: displayName,
            sessionPercent: nil,
            weeklyUsed: nil,
            weeklyLimit: nil,
            weeklyPercent: nil,
            resetsAt: nil,
            credits: nil,
            spend: nil,
            spendCap: nil,
            plan: nil,
            status: status,
            lastUpdated: Date()
        )
    }
}

/// Every string here follows the user's locale the way System Settings does:
/// the 12/24-hour clock, the day-month order, the currency symbol, the unit
/// words in a span. Callers pass a `locale` only in tests; the app reads
/// `.autoupdatingCurrent`, so flipping 24-Hour Time re-renders the card.
enum UsageFormatting {
    /// "resets Mon 9:00 AM" (or "Mon 09:00" on a 24-hour clock) within the
    /// week, "resets Oct 1" (or "1 Oct") further out.
    static func resetString(_ date: Date, now: Date = Date(), locale: Locale = .autoupdatingCurrent) -> String {
        if date.timeIntervalSince(now) < 6 * 24 * 3600 {
            return "resets " + date.formatted(Date.FormatStyle(locale: locale).weekday(.abbreviated).hour().minute())
        }
        return "resets " + date.formatted(Date.FormatStyle(locale: locale).day().month(.abbreviated))
    }

    /// The UTC month `date` falls in, as "SEP": every `.month` spend is
    /// measured over the UTC month (OpenRouter's `usage_monthly`, the two org
    /// cost reports), so the caption names that month, not the local one.
    static func currentMonthAbbreviation(_ date: Date = Date(), locale: Locale = .autoupdatingCurrent) -> String {
        date.formatted(Date.FormatStyle(locale: locale, timeZone: .gmt).month(.abbreviated)).uppercased()
    }

    /// "at 2:32 PM" (or "at 14:32") for a time later today, "shortly" if
    /// it's basically now.
    static func clockString(_ date: Date, now: Date = Date(), locale: Locale = .autoupdatingCurrent) -> String {
        date.timeIntervalSince(now) < 30 ? "shortly" : "at " + date.formatted(Date.FormatStyle(locale: locale).hour().minute())
    }

    static func lastUpdatedString(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 10 { return "just now" }
        if seconds < 90 { return "\(Int(seconds))s ago" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 48 * 3600 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86400))d ago"
    }

    /// 950 → "950", 12_400 → "12.4K", 440_500_000 → "441M", 1_200_000_000 → "1.2B".
    static func compactTokens(_ value: Double) -> String {
        let magnitude = abs(value)
        func scaled(_ divisor: Double, _ suffix: String) -> String {
            let scaled = value / divisor
            if abs(scaled) < 100 {
                let tenths = (scaled * 10).rounded() / 10
                return tenths == tenths.rounded()
                    ? String(format: "%.0f%@", tenths, suffix)
                    : String(format: "%.1f%@", tenths, suffix)
            }
            return String(format: "%.0f%@", scaled.rounded(), suffix)
        }
        switch magnitude {
        case ..<1_000: return String(format: "%.0f", value)
        case ..<1_000_000: return scaled(1_000, "K")
        case ..<1_000_000_000: return scaled(1_000_000, "M")
        default: return scaled(1_000_000_000, "B")
        }
    }

    /// US dollars the way the user's locale writes them: "$12.50" here,
    /// "US$12.50" in Britain, "12,50 $" in Germany. Every spend and estimate
    /// AIrail shows is USD; the code, not the symbol, is what's fixed.
    static func dollars(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        value.formatted(.currency(code: "USD").locale(locale))
    }

    /// Credits as a count ("8,760") or, with a currency, as money ("$12.34",
    /// "CN¥88.00"), both in the user's locale.
    static func credits(_ value: Double, currency: String?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let currency else { return Int(value).formatted(.number.locale(locale)) }
        return value.formatted(.currency(code: currency.uppercased()).locale(locale))
    }

    /// The footer's caption over a spend figure, naming the window it covers:
    /// "SPEND (SEP)", "SPEND (THIS CYCLE)", "SPEND (ALL TIME)", "SPEND (KEY LIMIT)".
    static func spendCaption(_ period: SpendPeriod, now: Date = Date()) -> String {
        switch period {
        case .month: return "SPEND (\(currentMonthAbbreviation(now)))"
        case .billingCycle: return "SPEND (THIS CYCLE)"
        case .lifetime: return "SPEND (ALL TIME)"
        case .keyLimit: return "SPEND (KEY LIMIT)"
        }
    }

    /// The same window as a spoken label: "Spend this month".
    static func spendLabel(_ period: SpendPeriod) -> String {
        switch period {
        case .month: return "Spend this month"
        case .billingCycle: return "Spend this billing cycle"
        case .lifetime: return "Spend, all time"
        case .keyLimit: return "Spend against the key limit"
        }
    }

    /// Model ids the way people say them: "claude-opus-4-8" → "Opus 4.8",
    /// "gpt-5.5-mini" → "GPT-5.5 Mini", "cursor-grok-4.6-high-fast" → "Grok 4.6 High Fast".
    static func modelDisplayName(_ id: String) -> String {
        var name = id.lowercased()
        for prefix in ["claude-", "cursor-", "models/"] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        if name.hasPrefix("gpt-") {
            let rest = name.dropFirst(4).split(separator: "-").map { word -> String in
                word.first?.isNumber == true ? String(word) : word.capitalized
            }
            return (["GPT-" + (rest.first ?? "")] + rest.dropFirst()).joined(separator: " ")
        }
        // Version digits separated by dashes read as dots: "opus-4-8" → "opus 4.8".
        var words: [String] = []
        for word in name.split(separator: "-").map(String.init) {
            if let last = words.last, word.allSatisfy(\.isNumber), last.last?.isNumber == true {
                words[words.count - 1] = last + "." + word
            } else {
                words.append(word)
            }
        }
        return words.map { $0.first?.isNumber == true ? $0 : $0.capitalized }.joined(separator: " ")
    }
}
