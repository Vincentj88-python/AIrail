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

/// What to do about the numbers, in one sentence — the reading a meter
/// can't give. Plain rules on live figures, the clock and the pace
/// projection, ranked by how soon they matter: a spent window, a limit the
/// current pace reaches before the reset, then capacity already paid for
/// that expires unused at the reset. Never from a stale or failed reading.
struct UsageAdvice: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// A window is spent; the wall lifts at `until`.
        case atWall(until: Date)
        /// At this pace the limit arrives at `hitsAt`, before the window
        /// resets at `resetsAt`.
        case wallAhead(hitsAt: Date, resetsAt: Date?)
        /// The window resets at `resetsAt` with `unused` points left.
        case useItOrLoseIt(unused: Double, resetsAt: Date, window: String)
    }

    enum Tone: Sendable, Equatable {
        case critical, warning, opportunity
    }

    /// One account as the rules see it.
    struct Input: Sendable {
        let id: String
        let name: String
        let snapshot: UsageSnapshot?
        let projection: UsageProjection?
        /// A tool's plan: its windows reset, so unused capacity expires. A
        /// keyed balance doesn't, so it never gets use-it-or-lose-it.
        let resets: Bool
    }

    let accountId: String
    let accountName: String
    let kind: Kind
    /// Another account comfortably under its limits, for the wall cases.
    let switchTo: HeadroomSummary.Account?
    /// Read from demo numbers; the sentence is real logic on made-up data.
    let isDemo: Bool

    /// How close a session reset must be for its leftovers to be worth a
    /// nudge, and how much must be left.
    static let sessionHorizon: TimeInterval = 90 * 60
    static let sessionUnused: Double = 40
    /// The same for the longer window: a day for a week, three for a month.
    static let weekHorizon: TimeInterval = 24 * 3600
    static let monthHorizon: TimeInterval = 72 * 3600
    static let periodUnused: Double = 30

    /// Every account's most pressing advice, most urgent first; at most one
    /// per account, and nothing for an account that is simply fine.
    static func advise(_ inputs: [Input], now: Date = Date()) -> [UsageAdvice] {
        let live = inputs.filter { $0.snapshot?.status == .ok || $0.snapshot?.status == .demo }
        let advice = live.compactMap { input -> UsageAdvice? in
            guard let snapshot = input.snapshot,
                  let kind = kind(for: snapshot, projection: input.projection, resets: input.resets, now: now)
            else { return nil }
            let wall: Bool
            switch kind {
            case .atWall, .wallAhead: wall = true
            case .useItOrLoseIt: wall = false
            }
            return UsageAdvice(
                accountId: input.id,
                accountName: input.name,
                kind: kind,
                switchTo: wall ? room(besides: input.id, in: live, status: snapshot.status) : nil,
                isDemo: snapshot.status == .demo
            )
        }
        return advice.sorted { $0.urgency < $1.urgency }
    }

    private static func kind(for snapshot: UsageSnapshot, projection: UsageProjection?, resets: Bool, now: Date) -> Kind? {
        if let until = snapshot.atLimitResetsAt, until > now {
            return .atWall(until: until)
        }
        if let projection, !projection.resetsFirst, projection.hitsLimitAt > now {
            return .wallAhead(hitsAt: projection.hitsLimitAt, resetsAt: snapshot.ringResetsAt)
        }
        guard resets else { return nil }
        // The longer window first: a week's leftovers are worth more than a
        // session's. A session's are only worth spending while the week has
        // room for them — spending them would otherwise bring the weekly wall closer.
        if let percent = snapshot.weeklyPercent,
           let reset = snapshot.weeklyResetsAt ?? (snapshot.sessionPercent == nil ? snapshot.resetsAt : nil),
           reset > now,
           reset.timeIntervalSince(now) <= (snapshot.periodLabel == "weekly" ? weekHorizon : monthHorizon),
           100 - percent >= periodUnused {
            return .useItOrLoseIt(unused: 100 - percent, resetsAt: reset, window: noun(forPeriod: snapshot.periodLabel))
        }
        if let percent = snapshot.sessionPercent, percent > 0,
           let reset = snapshot.resetsAt, reset > now,
           reset.timeIntervalSince(now) <= sessionHorizon,
           100 - percent >= sessionUnused,
           (snapshot.weeklyPercent ?? 0) < 70 {
            return .useItOrLoseIt(unused: 100 - percent, resetsAt: reset, window: "session")
        }
        return nil
    }

    /// The account with the most room under the warning line, other than
    /// `id`, from readings of the same kind (demo with demo, live with live).
    private static func room(besides id: String, in inputs: [Input], status: UsageStatus) -> HeadroomSummary.Account? {
        var best: HeadroomSummary.Account?
        for input in inputs where input.id != id {
            guard let snapshot = input.snapshot, snapshot.status == status,
                  snapshot.atLimitResetsAt == nil,
                  let percent = snapshot.peakPercent, UsageSeverity.of(percent) == .normal
            else { continue }
            if best.map({ percent < $0.percent }) ?? true {
                best = HeadroomSummary.Account(id: input.id, name: input.name, percent: percent, resetsAt: snapshot.peakResetsAt, status: snapshot.status)
            }
        }
        return best
    }

    /// "weekly" → "week", "monthly premium" → "month", "billing cycle" stays.
    static func noun(forPeriod label: String) -> String {
        if label == "weekly" { return "week" }
        if label.hasPrefix("month") { return "month" }
        return label
    }

    /// Spent walls first (soonest to lift first), then walls ahead (soonest
    /// first), then the most unused capacity.
    private var urgency: Double {
        switch kind {
        case .atWall(let until): return until.timeIntervalSinceReferenceDate / 1e12
        case .wallAhead(let hitsAt, _): return 1 + hitsAt.timeIntervalSinceReferenceDate / 1e12
        case .useItOrLoseIt(let unused, _, _): return 3 - unused / 100
        }
    }

    var tone: Tone {
        switch kind {
        case .atWall: return .critical
        case .wallAhead: return .warning
        case .useItOrLoseIt: return .opportunity
        }
    }

    var symbolName: String {
        switch kind {
        case .atWall: return "hand.raised.fill"
        case .wallAhead: return "speedometer"
        case .useItOrLoseIt: return "hourglass"
        }
    }

    /// The small caps line above the sentence.
    var headline: String {
        switch kind {
        case .atWall: return "At the limit"
        case .wallAhead: return "Limit ahead"
        case .useItOrLoseIt: return "Use it or lose it"
        }
    }

    /// The one sentence, e.g. "At this pace Claude hits its limit at 4:15 PM,
    /// 45m before it resets. Codex has 88% left."
    func sentence(now: Date = Date(), locale: Locale = .autoupdatingCurrent) -> String {
        var text: String
        switch kind {
        case .atWall(let until):
            text = "\(accountName) is at its limit for another \(UsageFormatting.countdown(to: until, now: now, locale: locale)), until \(Self.moment(until, now: now, locale: locale))."
        case .wallAhead(let hitsAt, let resetsAt):
            text = "At this pace \(accountName) hits its limit at \(Self.moment(hitsAt, now: now, locale: locale))"
            if let resetsAt, resetsAt > hitsAt {
                text += ", \(UsageFormatting.duration(hours: resetsAt.timeIntervalSince(hitsAt) / 3600, locale: locale)) before it resets."
            } else {
                text += "."
            }
        case .useItOrLoseIt(let unused, let resetsAt, let window):
            text = "\(accountName)'s \(window) resets in \(UsageFormatting.countdown(to: resetsAt, now: now, locale: locale)) with \(Int(unused.rounded()))% unused — "
            text += window == "session" ? "a good moment for the big task." : "capacity you've paid for that won't carry over."
        }
        if let switchTo {
            text += " \(switchTo.name) has \(Int((100 - switchTo.percent).rounded()))% left."
        }
        return text
    }

    /// The island's one-line form, e.g. "Claude 62% unused · resets in 40m".
    func caption(now: Date = Date(), locale: Locale = .autoupdatingCurrent) -> String {
        switch kind {
        case .atWall(let until):
            let base = "\(accountName) at limit · \(UsageFormatting.countdown(to: until, now: now, locale: locale))"
            return switchTo.map { base + " · \($0.name) has room" } ?? base
        case .wallAhead(let hitsAt, _):
            let base = "\(accountName) limit ≈ \(UsageFormatting.timeString(hitsAt, locale: locale))"
            return switchTo.map { base + " · \($0.name) has room" } ?? base
        case .useItOrLoseIt(let unused, let resetsAt, _):
            return "\(accountName) \(Int(unused.rounded()))% unused · resets in \(UsageFormatting.countdown(to: resetsAt, now: now, locale: locale))"
        }
    }

    /// "4:15 PM" today, "Mon 4:15 PM" later in the week.
    private static func moment(_ date: Date, now: Date, locale: Locale) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? UsageFormatting.timeString(date, locale: locale)
            : UsageFormatting.weekdayTime(date, locale: locale)
    }
}
