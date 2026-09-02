import Foundation
import UserNotifications

/// Native macOS notifications for the moments worth interrupting for: crossing
/// a usage threshold, and a session window resetting so you can batch heavy
/// work. Opt-in; fires at most once per event per window.
@MainActor
final class UsageNotifier {
    private var authorized = false
    private var requested = false
    /// Highest threshold already announced for the current window, per provider.
    private var lastThreshold: [String: Int] = [:]
    /// Session percent seen last refresh, to spot a window reset (a big drop).
    private var lastPercent: [String: Double] = [:]

    private let thresholds = [90, 75]

    func enableIfNeeded() {
        guard !requested else { return }
        requested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
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
        UNUserNotificationCenter.current().add(request)
    }
}

private extension String {
    var capitalizedFirst: String {
        isEmpty ? self : prefix(1).uppercased() + dropFirst()
    }
}
