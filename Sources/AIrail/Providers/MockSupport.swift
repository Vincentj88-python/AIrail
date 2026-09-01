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

/// Shared demo-data engine each provider uses to produce a realistic snapshot.
@MainActor
final class MockUsageEngine {
    struct Profile {
        var plan: String
        var sessionStart: Double   // starting session percent
        var weeklyLimit: Double    // weekly request budget
        var weeklyStart: Double    // starting weekly percent
        var credits: Double?
        var spend: Double?
        var spendCap: Double?
    }

    private let profile: Profile
    private let sessionWalk: RandomWalk
    private let weeklyWalk: RandomWalk
    private let spendWalk: RandomWalk?
    private var history: [Double]

    init(profile: Profile) {
        self.profile = profile
        sessionWalk = RandomWalk(start: profile.sessionStart, maxStep: 2.2)
        weeklyWalk = RandomWalk(start: profile.weeklyStart, maxStep: 0.6)
        spendWalk = profile.spend.map {
            RandomWalk(start: $0, range: 0...(profile.spendCap ?? $0 * 3), maxStep: 0.35)
        }
        let dailyAverage = profile.weeklyLimit * profile.weeklyStart / 100 / 7
        history = (0..<7).map { _ in max(0, (dailyAverage * Double.random(in: 0.55...1.45)).rounded()) }
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
            sessionUsed: nil,
            sessionLimit: nil,
            sessionPercent: sessionPercent,
            weeklyUsed: weeklyUsed,
            weeklyLimit: profile.weeklyLimit,
            weeklyPercent: weeklyPercent,
            resetsAt: Self.nextMondayNine(),
            credits: profile.credits,
            spend: spendWalk?.step(),
            spendCap: profile.spendCap,
            plan: profile.plan,
            status: .demo,
            lastUpdated: Date(),
            weeklyHistory: history
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
