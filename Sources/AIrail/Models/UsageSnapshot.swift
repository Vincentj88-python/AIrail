import Foundation

enum UsageStatus: String, Sendable {
    case ok, demo, stale, error, outage

    /// The word shown on the status pill. `ok` reads as "live" to a human.
    var label: String {
        self == .ok ? "live" : rawValue
    }
}

struct UsageSnapshot: Identifiable, Sendable {
    var id: String { providerId }
    var providerId: String
    var displayName: String
    var sessionUsed: Double?
    var sessionLimit: Double?
    var sessionPercent: Double?   // 0...100
    var weeklyUsed: Double?
    var weeklyLimit: Double?
    var weeklyPercent: Double?
    var resetsAt: Date?
    var credits: Double?
    var spend: Double?
    var spendCap: Double?
    var plan: String?
    var status: UsageStatus
    var lastUpdated: Date
    var weeklyHistory: [Double]   // 7 points, oldest first
    /// What the "weekly" numbers actually cover for this provider: some meter
    /// a calendar month or a billing cycle instead of a rolling week.
    var periodLabel: String = "weekly"
    /// When the longer window resets, if the provider reports it separately.
    var weeklyResetsAt: Date? = nil
    /// Who is signed in (an email or handle), when the source reveals it.
    var account: String? = nil
    /// Hourly/daily buckets, model and project shares, meters — whatever the
    /// source exposes beyond the headline numbers.
    var detail: UsageDetail? = nil
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

    /// The seven local days covered by `weeklyHistory`, oldest first, ending today.
    var historyDates: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<weeklyHistory.count).compactMap {
            calendar.date(byAdding: .day, value: $0 - (weeklyHistory.count - 1), to: today)
        }
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
            sessionUsed: nil,
            sessionLimit: nil,
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
            lastUpdated: Date(),
            weeklyHistory: []
        )
    }
}

enum UsageFormatting {
    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter
    }()

    private static let resetDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter
    }()

    /// "resets Mon 09:00" within the week, "resets 1 Oct" further out.
    static func resetString(_ date: Date, now: Date = Date()) -> String {
        if date.timeIntervalSince(now) < 6 * 24 * 3600 {
            return "resets " + resetFormatter.string(from: date)
        }
        return "resets " + resetDayFormatter.string(from: date)
    }

    static func currentMonthAbbreviation(_ date: Date = Date()) -> String {
        monthFormatter.string(from: date).uppercased()
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

    static func dollars(_ value: Double) -> String {
        String(format: "$%.2f", value)
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
