import Foundation

/// A slow random walk around a base value so demo numbers look alive
/// between refreshes instead of jumping to a new random jumble.
@MainActor
final class RandomWalk {
    private(set) var value: Double
    private let range: ClosedRange<Double>
    private let maxStep: Double

    init(start: Double, range: ClosedRange<Double> = 1...97, maxStep: Double = 1.8) {
        self.value = min(max(start, range.lowerBound), range.upperBound)
        self.range = range
        self.maxStep = maxStep
    }

    @discardableResult
    func step() -> Double {
        let delta = Double.random(in: -maxStep...maxStep)
        value = min(max(value + delta, range.lowerBound), range.upperBound)
        return value
    }
}

/// Demo-data engine used while no account is connected, so the rail has
/// something realistic to show. Every snapshot it makes is marked `demo`.
@MainActor
final class MockUsageEngine {
    struct Profile: Sendable {
        var plan: String
        var sessionStart: Double   // starting session percent
        var weeklyLimit: Double    // weekly request budget
        var weeklyStart: Double    // starting weekly percent
        var credits: Double?
        var spend: Double?
        var spendCap: Double?
        var spendPeriod: SpendPeriod = .month
        /// Model ids the demo "by model" list uses, most used first.
        var demoModels: [String] = ["demo-model-large", "demo-model-small"]
    }

    private let profile: Profile
    private let sessionWalk: RandomWalk
    private let weeklyWalk: RandomWalk
    private let spendWalk: RandomWalk?
    private var history: [Double]
    private let hourlyShape: [Double]
    /// A rolling 5-hour window that started 1–4 hours ago, like the real ones.
    private let sessionResetsAt = Date().addingTimeInterval(Double.random(in: 1...4) * 3600)

    init(profile: Profile) {
        self.profile = profile
        sessionWalk = RandomWalk(start: profile.sessionStart, maxStep: 2.2)
        weeklyWalk = RandomWalk(start: profile.weeklyStart, maxStep: 0.6)
        spendWalk = profile.spend.map {
            RandomWalk(start: $0, range: 0...(profile.spendCap ?? $0 * 3), maxStep: 0.35)
        }
        let dailyAverage = profile.weeklyLimit * profile.weeklyStart / 100 / 7
        history = (0..<7).map { _ in max(0, (dailyAverage * Double.random(in: 0.55...1.45)).rounded()) }
        // A working day: quiet overnight, busy late morning and mid-afternoon.
        hourlyShape = (0..<24).map { hour in
            let h = Double(hour)
            let morning = exp(-pow((h - 11) / 2.2, 2))
            let afternoon = exp(-pow((h - 15.5) / 2.5, 2))
            return max(0, morning + 0.8 * afternoon + Double.random(in: -0.08...0.08))
        }
    }

    func snapshot(providerId: String, displayName: String) -> UsageSnapshot {
        let sessionPercent = UsageSnapshot.clampPercent(sessionWalk.step())
        let weeklyPercent = UsageSnapshot.clampPercent(weeklyWalk.step())
        let weeklyUsed = (profile.weeklyLimit * weeklyPercent / 100).rounded()
        // Nudge only today's point so the sparkline drifts instead of reshuffling.
        if let today = history.last {
            history[history.count - 1] = max(0, (today + Double.random(in: -3...5)).rounded())
        }
        return UsageSnapshot(
            providerId: providerId,
            displayName: displayName,
            sessionPercent: sessionPercent,
            weeklyUsed: weeklyUsed,
            weeklyLimit: profile.weeklyLimit,
            weeklyPercent: weeklyPercent,
            resetsAt: sessionResetsAt,
            credits: profile.credits,
            spend: spendWalk?.step(),
            spendCap: profile.spendCap,
            spendPeriod: profile.spendPeriod,
            plan: profile.plan,
            status: .demo,
            lastUpdated: Date(),
            weeklyResetsAt: Self.nextMondayNine(),
            sessionWindowLength: 5 * 3600,
            periodStartsAt: Self.nextMondayNine().addingTimeInterval(-7 * 24 * 3600),
            detail: demoDetail()
        )
    }

    /// Detail that exercises every section of the overlay with obviously
    /// placeholder names; the badge on top still says demo.
    private func demoDetail(now: Date = Date()) -> UsageDetail {
        let calendar = Calendar.current
        let requestsToday = history.last ?? 0
        let tokensPerRequest = 12_000.0
        var hours: [Date: UsageAggregate] = [:]
        let shapeTotal = max(0.001, hourlyShape.reduce(0, +))
        for offset in 0..<24 {
            guard let start = calendar.date(byAdding: .hour, value: -offset, to: UsageBucketing.floor(now, to: .hour, calendar: calendar)) else { continue }
            let hour = calendar.component(.hour, from: start)
            let share = hourlyShape[hour] / shapeTotal
            var usage = UsageAggregate()
            usage.messages = Int((requestsToday * share).rounded())
            let tokens = Double(usage.messages) * tokensPerRequest
            usage.tokens = TokenSplit(input: tokens * 0.08, output: tokens * 0.05, cacheWrite: tokens * 0.12, cacheRead: tokens * 0.75)
            usage.thinking = usage.tokens.output * 0.4
            hours[start] = usage
        }
        var days: [Date: UsageAggregate] = [:]
        var week = UsageAggregate()
        for (index, requests) in history.enumerated() {
            guard let day = calendar.date(byAdding: .day, value: index - (history.count - 1), to: calendar.startOfDay(for: now)) else { continue }
            var usage = UsageAggregate()
            usage.messages = Int(requests)
            let tokens = requests * tokensPerRequest
            usage.tokens = TokenSplit(input: tokens * 0.08, output: tokens * 0.05, cacheWrite: tokens * 0.12, cacheRead: tokens * 0.75)
            usage.thinking = usage.tokens.output * 0.4
            for (rank, model) in profile.demoModels.enumerated() {
                usage.models[model] = tokens * [0.62, 0.28, 0.10][min(rank, 2)]
            }
            usage.projects = ["demo-app": tokens * 0.55, "side-project": tokens * 0.3, "dotfiles": tokens * 0.15]
            usage.toolCalls = ["Bash": Int(requests * 0.3), "Edit": Int(requests * 0.2), "Read": Int(requests * 0.15)]
            usage.sessions = Set((0..<max(1, Int(requests / 40))).map { "demo-\(index)-\($0)" })
            days[day] = usage
            week.merge(usage)
        }
        return UsageDetail(
            hours: UsageBucketing.series(hours, count: 24, component: .hour, endingAt: now, calendar: calendar),
            days: UsageBucketing.series(days, count: 7, component: .day, endingAt: now, calendar: calendar),
            week: week
        )
    }

    static func nextMondayNine(after date: Date = Date()) -> Date {
        let components = DateComponents(hour: 9, minute: 0, weekday: 2)
        return Calendar.current.nextDate(
            after: date, matching: components, matchingPolicy: .nextTime
        ) ?? date.addingTimeInterval(7 * 24 * 3600)
    }
}

/// Best-effort local install detection. Read-only filesystem checks; no
/// processes launched, nothing scraped.
enum InstallDetection {
    static func anyExists(_ homeRelativePaths: [String]) -> Bool {
        let home = NSHomeDirectory()
        return homeRelativePaths.contains {
            FileManager.default.fileExists(atPath: home + "/" + $0)
        }
    }

    static func onPath(_ tool: String) -> Bool {
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        // GUI apps get a minimal PATH; include the usual CLI install locations.
        directories += ["/usr/local/bin", "/opt/homebrew/bin"]
        return directories.contains {
            FileManager.default.fileExists(atPath: $0 + "/" + tool)
        }
    }
}
