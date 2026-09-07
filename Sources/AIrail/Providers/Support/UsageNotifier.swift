import Foundation
import UserNotifications

/// Native macOS notifications for the moments worth interrupting for: crossing
/// a usage threshold, and a session window resetting so you can batch heavy
/// work. Opt-in; fires at most once per event per window.
@MainActor
final class UsageNotifier {
    /// Asks macOS for permission and reports whether it was granted. The real
    /// one puts up the one-time "AIrail would like to send you notifications"
    /// prompt, which is exactly why tests hand in their own answer.
    typealias Authorize = @MainActor (_ granted: @escaping @MainActor (Bool) -> Void) -> Void
    /// Hands a finished notification to Notification Center — or, in tests, to an array.
    typealias Deliver = @MainActor (UNNotificationRequest) -> Void

    private let authorize: Authorize
    private let deliver: Deliver
    private var authorized = false
    private var requested = false
    /// Highest threshold already announced for the current window, per provider.
    private var lastThreshold: [String: Int] = [:]
    /// Session percent seen last refresh, to spot a window reset (a big drop).
    private var lastPercent: [String: Double] = [:]

    private let thresholds = [90, 75]

    init(authorize: @escaping Authorize, deliver: @escaping Deliver) {
        self.authorize = authorize
        self.deliver = deliver
    }

    /// The real thing: Notification Center for both permission and delivery.
    convenience init() {
        self.init(authorize: Self.systemAuthorize, deliver: Self.systemDeliver)
    }

    func enableIfNeeded() {
        guard !requested else { return }
        requested = true
        authorize { [weak self] granted in
            self?.authorized = granted
        }
    }

    /// Called on each refresh with the latest snapshot for a connected account.
    func consider(_ snapshot: UsageSnapshot, enabled: Bool) {
        guard enabled, snapshot.status == .ok else { return }
        enableIfNeeded()
        let id = snapshot.providerId
        let percent = snapshot.ringPercent ?? 0
        let previous = lastPercent[id]
        lastPercent[id] = percent

        // A sharp drop means the window reset — a good time to resume heavy work.
        if let previous, previous - percent >= 25, previous >= 30 {
            lastThreshold[id] = nil
            notify(
                id: "\(id).reset",
                title: "\(snapshot.displayName) usage reset",
                body: "Your \(snapshot.sessionPercent != nil ? "session" : snapshot.periodLabel) window is fresh — good time for heavy work."
            )
        }

        // Crossing a threshold, announced once until the window resets.
        let crossed = thresholds.first { Int(percent) >= $0 }
        if let crossed, (lastThreshold[id] ?? 0) < crossed {
            lastThreshold[id] = crossed
            var body = "\(crossed)% of your \(snapshot.sessionPercent != nil ? "session" : snapshot.periodLabel) used."
            if let resets = snapshot.resetsAt ?? snapshot.weeklyResetsAt {
                body += " " + UsageFormatting.resetString(resets).capitalizedFirst
            }
            notify(id: "\(id).threshold", title: snapshot.displayName, body: body)
        }
    }

    func forget(_ providerId: String) {
        lastThreshold[providerId] = nil
        lastPercent[providerId] = nil
    }

    private func notify(id: String, title: String, body: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        let request = UNNotificationRequest(identifier: id + ".\(Int(Date().timeIntervalSince1970))", content: content, trigger: nil)
        deliver(request)
    }

    // MARK: Notification Center

    private static func systemAuthorize(_ granted: @escaping @MainActor (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            Task { @MainActor in granted(ok) }
        }
    }

    private static func systemDeliver(_ request: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(request)
    }
}

private extension String {
    var capitalizedFirst: String {
        isEmpty ? self : prefix(1).uppercased() + dropFirst()
    }
}
