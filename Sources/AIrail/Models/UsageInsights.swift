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
