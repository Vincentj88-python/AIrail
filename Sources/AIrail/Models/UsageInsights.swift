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

extension UsageFormatting {
    /// "35 min", "2.4 h", "1.5 days" — a rough, human span.
    static func duration(hours: Double) -> String {
        if hours < 1 { return "\(max(1, Int((hours * 60).rounded()))) min" }
        if hours < 48 { return String(format: "%.1f h", hours) }
        return String(format: "%.1f days", hours / 24)
    }
}
