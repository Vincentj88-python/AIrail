import Foundation

enum UsageStatus: String, Sendable {
    case ok, demo, stale, error, outage
}

struct UsageSnapshot: Identifiable, Sendable {
    var id: String { providerId }
    let providerId: String
    let displayName: String
    let sessionUsed: Double?
    let sessionLimit: Double?
    let sessionPercent: Double?   // 0...100
    let weeklyUsed: Double?
    let weeklyLimit: Double?
    let weeklyPercent: Double?
    let resetsAt: Date?
    let credits: Double?
    let spend: Double?
    let spendCap: Double?
    let plan: String?
    let status: UsageStatus
    let lastUpdated: Date
    let weeklyHistory: [Double]   // 7 points, oldest first
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
}

enum UsageFormatting {
    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter
    }()

    static func resetString(_ date: Date) -> String {
        "resets " + resetFormatter.string(from: date)
    }

    static func currentMonthAbbreviation(_ date: Date = Date()) -> String {
        monthFormatter.string(from: date).uppercased()
    }

    static func lastUpdatedString(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 10 { return "just now" }
        if seconds < 90 { return "\(Int(seconds))s ago" }
        return "\(Int(seconds / 60))m ago"
    }
}
