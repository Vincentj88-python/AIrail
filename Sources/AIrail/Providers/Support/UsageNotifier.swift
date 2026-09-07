import Foundation
import UserNotifications

/// Native macOS notifications for the moments worth interrupting for: crossing
/// a usage threshold, and that window resetting so you can batch heavy work.
/// Opt-in; each threshold is announced once per window (remembered across
/// relaunches), the reset once, at the time the provider itself reported.
/// Every alert is grouped under its account and carries the provider id, so
/// a click opens that HUD (see `AppDelegate`).
@MainActor
final class UsageNotifier {
    /// Whether macOS will show AIrail's notifications right now. Read at the
    /// moment of delivery rather than remembered from launch, so the first
    /// alert after launch — or the one right after Allow — isn't lost, and a
    /// permission flipped in System Settings is honoured without a relaunch.
    typealias Authorization = @MainActor () async -> Bool
    /// Hands a notification to Notification Center — or, in tests, to an
    /// array. Alerts carry no trigger; the reset alert carries its time.
    typealias Deliver = @MainActor (UNNotificationRequest) -> Void
    /// Takes back pending requests by identifier (a scheduled reset alert).
    typealias Withdraw = @MainActor ([String]) -> Void

    private let defaults: UserDefaults
    private let now: () -> Date
    private let authorization: Authorization
    private let deliver: Deliver
    private let withdraw: Withdraw
    /// Per provider and window, the highest threshold announced, under
    /// "<providerId>.<reset time in unix seconds>" — "<providerId>.none" when
    /// the provider reports no reset. Kept in defaults so a relaunch at 80%
    /// doesn't say 75 again, one mark per window so a ring that swaps between
    /// its session and weekly windows keeps both; marks for windows already
    /// past are dropped whenever one is written.
    private var announced: [String: Int] {
        didSet { defaults.set(announced, forKey: Self.announcedKey) }
    }
    /// The window (unix seconds) each provider's reset alert is scheduled
    /// for, so the 90% alert doesn't reschedule what the 75% one did.
    private var scheduledResets: [String: Int] = [:]

    private static let announcedKey = "announcedThresholds"
    private let thresholds = [90, 75]

    init(
        defaults: UserDefaults,
        now: @escaping () -> Date = { Date() },
        authorization: @escaping Authorization,
        deliver: @escaping Deliver,
        withdraw: @escaping Withdraw
    ) {
        self.defaults = defaults
        self.now = now
        self.authorization = authorization
        self.deliver = deliver
        self.withdraw = withdraw
        announced = defaults.dictionary(forKey: Self.announcedKey) as? [String: Int] ?? [:]
    }

    /// The real thing: Notification Center for permission, delivery and withdrawal.
    convenience init() {
        self.init(
            defaults: .standard,
            authorization: { await Self.systemAuthorization() },
            deliver: { UNUserNotificationCenter.current().add($0) },
            withdraw: { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: $0) }
        )
    }

    /// Called on each refresh with the latest snapshot for a connected account.
    func consider(_ snapshot: UsageSnapshot, enabled: Bool) async {
        guard enabled, snapshot.status == .ok, let percent = snapshot.ringPercent else { return }
        let id = snapshot.providerId
        let window = snapshot.ringResetsAt.map { Int($0.timeIntervalSince1970) }
        let mark = Self.mark(id, window: window)
        var announcedBefore = announced[mark] ?? 0
        if Int(percent) < announcedBefore - 25 {
            // Well under what was announced, with no new reset time: the
            // meter was reset without saying so (a raised key limit). Start over.
            remember(nil, at: mark)
            announcedBefore = 0
        }
        let crossed = thresholds.first(where: { Int(percent) >= $0 })
        let announces = crossed.map { $0 > announcedBefore } ?? false
        let schedules = crossed != nil && window != nil && scheduledResets[id] != window
        // The wall: a spent window with a reset date, said once per window
        // under its own mark (keyed by that reset, so it expires with it).
        let wall = snapshot.atLimitResetsAt
        let wallMark = wall.map { "\(id).wall.\(Int($0.timeIntervalSince1970))" }
        let announcesWall = wallMark.map { announced[$0] == nil } ?? false
        guard announces || schedules || announcesWall else { return }
        // Permission is read at the moment of delivery, and a threshold is
        // remembered only once delivered, so an alert macOS wasn't yet allowed
        // to show (at launch, or with the prompt still up) comes through on
        // the next refresh instead of being lost.
        guard await authorization() else { return }
        // The account was removed while macOS was asked: nothing to say, and
        // nothing to remember for a read that no longer counts.
        guard !Task.isCancelled else { return }
        if announces, let crossed {
            remember(crossed, at: mark)
            var body = "\(crossed)% of your \(snapshot.ringWindowLabel) used."
            if let resets = snapshot.ringResetsAt {
                body += " " + UsageFormatting.resetString(resets, now: now()).capitalizedFirst
            }
            deliver(request("\(id).threshold.\(crossed)", providerId: id, title: snapshot.displayName, body: body))
        }
        if announcesWall, let wall, let wallMark {
            remember(100, at: wallMark)
            let body = "Limit reached. " + UsageFormatting.resetString(wall, now: now()).capitalizedFirst + "."
            deliver(request("\(id).wall", providerId: id, title: snapshot.displayName, body: body))
        }
        if schedules {
            scheduleReset(for: snapshot)
        }
    }

    /// An account removed: nothing remembered, nothing left pending.
    func forget(_ providerId: String) {
        announced = announced.filter { !$0.key.hasPrefix(providerId + ".") }
        scheduledResets[providerId] = nil
        withdraw(["\(providerId).reset"])
    }

    /// Takes back every pending reset alert — the toggle went off, or AIrail
    /// is quitting and must not speak for an app that isn't running.
    func withdrawResets(for providerIds: [String]) {
        scheduledResets = [:]
        withdraw(providerIds.map { "\($0).reset" })
    }

    private static func mark(_ providerId: String, window: Int?) -> String {
        "\(providerId).\(window.map(String.init) ?? "none")"
    }

    /// Writes one mark and drops every mark whose window has passed. A mark
    /// with no window has no clock to expire on; `forget` or the meter
    /// falling well under it is what clears that one.
    private func remember(_ threshold: Int?, at mark: String) {
        let cutoff = Int(now().timeIntervalSince1970)
        var kept = announced.filter { key, _ in
            guard let window = key.split(separator: ".").last.flatMap({ Int($0) }) else { return true }
            return window > cutoff
        }
        kept[mark] = threshold
        announced = kept
    }

    /// One alert at the time the provider itself says the window resets,
    /// scheduled once an account is past a threshold. From here the request
    /// is the system's — it fires even if AIrail has quit — which is why
    /// `forget`, the toggle and quitting withdraw it.
    private func scheduleReset(for snapshot: UsageSnapshot) {
        guard let resetsAt = snapshot.ringResetsAt else { return }
        let id = snapshot.providerId
        scheduledResets[id] = Int(resetsAt.timeIntervalSince1970)
        let interval = resetsAt.timeIntervalSince(now())
        guard interval > 1 else { return } // already past: nothing honest to schedule
        deliver(request(
            "\(id).reset",
            providerId: id,
            title: "\(snapshot.displayName) usage reset",
            body: "Your \(snapshot.ringWindowLabel) window is fresh — good time for heavy work.",
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        ))
    }

    private func request(
        _ identifier: String, providerId: String, title: String, body: String, trigger: UNNotificationTrigger? = nil
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        content.threadIdentifier = providerId // one group per account in Notification Center
        content.userInfo = ["providerId": providerId] // a click opens that account's HUD
        return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
    }

    // MARK: Notification Center

    /// AIrail's own row in System Settings › Notifications. The URL scheme is
    /// undocumented but long-standing; if it stops opening, nothing happens.
    static var systemSettingsURL: URL? {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleId)")
    }

    static func systemStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// The one-time system prompt, put up when the toggle goes on — not at
    /// the first alert. Reports what macOS decided once it's answered.
    static func requestPermission() async -> UNAuthorizationStatus {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await systemStatus()
    }

    /// Authorized (provisionally counts) means deliver; anything else, never
    /// asked included, means nothing: a background refresh must never raise
    /// the system prompt — the Settings toggle is the one place that asks.
    /// The update notification (`UpdateChecker`) reads the same answer.
    static func systemAuthorization() async -> Bool {
        switch await systemStatus() {
        case .authorized, .provisional: return true
        default: return false
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        isEmpty ? self : prefix(1).uppercased() + dropFirst()
    }
}
