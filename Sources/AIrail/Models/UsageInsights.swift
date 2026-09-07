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

/// The one reading the collapsed surfaces show, from the snapshots the rail
/// already has: which account is nearest its limit and how near, which other
/// account still has room, and when the nearest window resets. The hairline's
/// colour and fill, the idle island caption and VoiceOver all read this.
struct HeadroomSummary: Sendable, Equatable {
    struct Account: Sendable, Equatable {
        let id: String
        let name: String
        let percent: Double
        let resetsAt: Date?
        let status: UsageStatus
    }

    /// The account nearest its limit, judged by its peak window; nil when no
    /// account has a figure at all (the line stays whole and calm).
    let peak: Account?
    /// The account with the most room, when one is comfortably under the
    /// warning line — the one to switch to.
    let room: Account?

    var severity: UsageSeverity { .of(peak?.percent) }
    var accent: Color { severity.accent }
    /// How much of the hairline to light: the peak's share; nil for the whole line.
    var fill: Double? { peak.map { $0.percent / 100 } }
    /// "demo" or "stale" when the peak reading is one of those — a length is
    /// a more precise claim than a colour, so it says what it is.
    var qualifier: String? {
        guard let peak, peak.status != .ok else { return nil }
        return peak.status.label
    }

    static func of(_ accounts: [(id: String, name: String, snapshot: UsageSnapshot?)]) -> HeadroomSummary {
        let readings = accounts.compactMap { account -> Account? in
            guard let snapshot = account.snapshot, let percent = snapshot.peakPercent else { return nil }
            return Account(id: account.id, name: account.name, percent: percent, resetsAt: snapshot.peakResetsAt, status: snapshot.status)
        }
        var peak: Account?
        for reading in readings where peak.map({ reading.percent > $0.percent }) ?? true {
            peak = reading // first in rail order wins a tie
        }
        var room: Account?
        for reading in readings where reading.id != peak?.id && UsageSeverity.of(reading.percent) == .normal {
            if room.map({ reading.percent < $0.percent }) ?? true { room = reading }
        }
        return HeadroomSummary(peak: peak, room: room)
    }

    /// "Claude 91% · Codex 12% · resets 2:30 PM" — at most two accounts and
    /// the nearest reset when it is within the day (the island's caption row
    /// is one line wide, so a far reset is left to the card); nil when there
    /// is nothing to say.
    func caption(now: Date = Date(), locale: Locale = .autoupdatingCurrent) -> String? {
        captionVariants(now: now, locale: locale).first
    }

    /// The caption at three lengths, longest first — everything, then without
    /// the account with room, then the nearest limit alone — so a narrow
    /// island shows the longest one that fits rather than a truncated line.
    func captionVariants(now: Date = Date(), locale: Locale = .autoupdatingCurrent) -> [String] {
        guard let peak else { return [] }
        let peakText = "\(peak.name) \(Int(peak.percent.rounded()))%"
        let roomText = room.map { "\(room!.name) \(Int($0.percent.rounded()))%" }
        var resetText: String?
        if let resets = peak.resetsAt, resets > now, resets.timeIntervalSince(now) < 24 * 3600 {
            resetText = "resets \(UsageFormatting.timeString(resets, locale: locale))"
        }
        var variants = [[peakText, roomText, resetText].compactMap { $0 }.joined(separator: " · ")]
        if roomText != nil, let resetText { variants.append([peakText, resetText].joined(separator: " · ")) }
        if roomText != nil || resetText != nil { variants.append(peakText) }
        return variants
    }

    /// What VoiceOver says for the collapsed hairline.
    func spoken(now: Date = Date()) -> String {
        guard let peak else { return "AIrail, no usage figures yet" }
        var text = "\(peak.name) at \(Int(peak.percent.rounded())) percent, nearest to its limit"
        if let qualifier { text += " (\(qualifier))" }
        if let room { text += "; \(room.name) has room at \(Int(room.percent.rounded())) percent" }
        if let resets = peak.resetsAt, resets > now {
            text += "; " + UsageFormatting.resetString(resets, now: now)
        }
        return text
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
