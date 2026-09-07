import SwiftUI

/// How close a usage figure is to its limit — drives the ambient rail colour
/// and the notification thresholds.
enum UsageSeverity: Sendable {
    case normal, warning, critical

    static func of(_ percent: Double?) -> UsageSeverity {
        switch percent ?? 0 {
        case 90...: return .critical
        case 70..<90: return .warning
        default: return .normal
        }
    }

    /// The rail's calm accent when there's headroom, warming to amber then red.
    var accent: Color {
        switch self {
        case .normal: return Color(hex: 0x6E8BFF)   // periwinkle
        case .warning: return Color(hex: 0xF5A623)  // amber
        case .critical: return Color(hex: 0xFF4D4D) // red
        }
    }
}

/// A projection of when a climbing usage figure will hit its limit, from the
/// rate it's been climbing this session.
struct UsageProjection: Sendable, Equatable {
    /// Percentage points per hour.
    let ratePerHour: Double
    /// When it would reach 100% at this pace.
    let hitsLimitAt: Date
    /// The window resets before that — so you won't actually run out.
    let resetsFirst: Bool
    /// "session" or the provider's period label.
    let basis: String

    var hoursToLimit: Double { max(0, hitsLimitAt.timeIntervalSinceNow / 3600) }
}

/// Where a usage figure sits against the time elapsed in its window: plain
/// arithmetic on two live numbers and the clock, no slope fitting, nothing
/// estimated. 40% used with 40% of the window gone is an even pace.
struct UsagePace: Sendable, Equatable {
    /// How much of the window has elapsed, 0...1.
    let elapsed: Double
    /// Percentage points used minus the even-pace share of the window.
    let delta: Double
    /// Time left in the window.
    let remaining: TimeInterval
    /// "session" or the provider's period label.
    let basis: String

    static func of(percent: Double?, window: DateInterval?, basis: String, now: Date = Date()) -> UsagePace? {
        guard let percent, let window, window.duration > 0, now >= window.start, now < window.end else { return nil }
        let elapsed = now.timeIntervalSince(window.start) / window.duration
        return UsagePace(
            elapsed: elapsed,
            delta: percent - elapsed * 100,
            remaining: window.end.timeIntervalSince(now),
            basis: basis
        )
    }

    /// "12 pts above an even pace", "8 pts under an even pace", or the even pace itself.
    var summary: String {
        let points = Int(delta.rounded())
        if abs(points) < 3 { return "On an even pace through the \(basis)" }
        return "\(abs(points)) pts \(points > 0 ? "above" : "under") an even pace"
    }
}

/// The session figure moving while this Mac's tool wrote nothing — a second
/// Mac, the web app, the desktop app. Two rules on two live reads, phrased
/// as an observation about this Mac, never an attribution to another device.
struct UsageElsewhere: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// The window has usage but no counted local line since it began.
        case quietWindow
        /// The figure rose by `points` since `since` while the newest local line stayed put.
        case rose(points: Double, since: Date)
    }
    let kind: Kind

    /// What one account's reads have established so far; reset whenever the
    /// window changes, the Mac does something, or the figure drops.
    struct Watch: Sendable, Equatable {
        var window: Date?
        var newestLocal: Date?
        var anchorPercent: Double
        var anchorDate: Date
        var reads = 0
    }

    /// Only providers whose history comes from local transcripts, and only
    /// while those transcripts are being read at all (`hasActivity`), so a
    /// scanner pointed at the wrong folder never produces a claim.
    static func evaluate(_ snapshot: UsageSnapshot, watch: inout Watch?, now: Date = Date()) -> UsageElsewhere? {
        guard snapshot.status == .ok, let percent = snapshot.sessionPercent, let window = snapshot.sessionWindow else {
            watch = nil
            return nil
        }
        let newest = snapshot.detail.newestLocalEvent
        let fresh = Watch(window: snapshot.resetsAt, newestLocal: newest, anchorPercent: percent, anchorDate: now)
        // The Mac just did something: the figure may still be catching up
        // with it, so nothing is observed and the next quiet read anchors.
        if let newest, newest > now.addingTimeInterval(-120) {
            watch = fresh
            return nil
        }
        var current = watch ?? fresh
        if current.reads == 0 || current.window != snapshot.resetsAt || current.newestLocal != newest || percent < current.anchorPercent {
            current = fresh
        }
        current.reads += 1
        watch = current
        guard snapshot.detail.hasActivity else { return nil }
        if percent >= 3, newest.map({ $0 < window.start.addingTimeInterval(-120) }) ?? true {
            return UsageElsewhere(kind: .quietWindow)
        }
        let rise = percent - current.anchorPercent
        if current.reads >= 2, rise >= 3 {
            return UsageElsewhere(kind: .rose(points: rise, since: current.anchorDate))
        }
        return nil
    }

    /// "No Claude Code activity on this Mac this session", or
    /// "Up 12 pts since 2:02 PM with no Claude Code activity on this Mac".
    func summary(tool: String, locale: Locale = .autoupdatingCurrent) -> String {
        switch kind {
        case .quietWindow:
            return "No \(tool) activity on this Mac this session"
        case .rose(let points, let since):
            let time = since.formatted(Date.FormatStyle(locale: locale).hour().minute())
            return "Up \(Int(points.rounded())) pts since \(time) with no \(tool) activity on this Mac"
        }
    }
}

extension UsageFormatting {
    /// "30m", "2h 24m", "3d 4h" — a span the way the Battery pane writes one.
    /// Hours and minutes under two days, days and hours beyond; never "0m",
    /// because a limit seconds away is still a minute away to a person.
    static func duration(hours: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let seconds = max(60, hours * 3600)
        let units: Set<Duration.UnitsFormatStyle.Unit> = hours < 48 ? [.hours, .minutes] : [.days, .hours]
        return Duration.seconds(seconds).formatted(.units(allowed: units, width: .narrow).locale(locale))
    }
}
