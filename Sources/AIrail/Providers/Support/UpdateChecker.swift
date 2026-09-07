import AppKit
import UserNotifications

/// A lightweight "is there a newer release?" check against the project's GitHub
/// releases. It notifies and hands off the download — it does not replace the
/// app in place (that's Sparkle's job, added when the repo goes public and the
/// app is notarized). Works the moment the repo/releases are public; while the
/// repo is private the API returns 404 and a manual check just says so.
///
/// Two paths, deliberately different: the menu item asked, so it gets an
/// alert either way; the hourly timer didn't, so it only ever posts one
/// notification per release version and relabels the menu — never a window
/// over someone's work.
@MainActor
enum UpdateChecker {
    static let repo = "Vincentj88-python/AIrail"
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }

    private static let lastCheckKey = "lastUpdateCheck"
    private static let notifiedVersionKey = "notifiedUpdateVersion"
    private static let minInterval: TimeInterval = 24 * 3600
    private static let tickInterval: TimeInterval = 3600

    /// The notification's category and its one action; `AppDelegate`
    /// registers the category and routes both.
    nonisolated static let categoryIdentifier = "update"
    nonisolated static let downloadActionIdentifier = "download"

    struct Release: Equatable, Sendable {
        let version: String
        let notes: String
        let page: URL
        let dmg: URL?
    }

    /// Where each check's answer goes — the newer release, or nil when there
    /// isn't one — so the menus can read "Update to 0.2.1…".
    private static var report: (@MainActor (Release?) -> Void)?
    private static var timer: Timer?

    // MARK: Entry points

    /// The "Check for Updates…" menu item. Always reports back to the user.
    static func checkForUpdates() {
        Task { await check(userInitiated: true) }
    }

    /// The same item once it reads "Update to x.y.z…": the release the last
    /// check found, shown straight away rather than fetched again.
    static func show(_ release: Release) {
        Task { await presentUpdate(release, userInitiated: true) }
    }

    /// The quiet checks: one now if a day has passed since the last, then an
    /// hourly tick (with tolerance, so the system can coalesce it) that does
    /// the same — an app left running for weeks still looks once a day. Only
    /// speaks up when there's actually a newer version.
    static func startBackgroundChecks(reporting report: @escaping @MainActor (Release?) -> Void) {
        self.report = report
        clearStaleAnnouncement()
        checkInBackgroundIfDue()
        // Same shape as ProviderManager's refresh timer: main run loop, .common
        // mode, silent while the Mac sleeps.
        let timer = Timer(timeInterval: tickInterval, repeats: true) { _ in
            Task { @MainActor in Self.checkInBackgroundIfDue() }
        }
        timer.tolerance = tickInterval / 6
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// A notification still sitting in Notification Center for the release
    /// now running (or one older) is taken down, and its version forgotten,
    /// so the next release gets its own.
    private static func clearStaleAnnouncement() {
        let defaults = UserDefaults.standard
        guard let notified = defaults.string(forKey: notifiedVersionKey),
              !isNewer(notified, than: currentVersion)
        else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [categoryIdentifier])
        defaults.removeObject(forKey: notifiedVersionKey)
    }

    private static func checkInBackgroundIfDue() {
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
        if let last, Date().timeIntervalSince(last) < minInterval { return }
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        Task { await check(userInitiated: false) }
    }

    /// What the menu item says: the release the last check found, else the ask.
    static func menuTitle(for release: Release?) -> String {
        release.map { "Update to \($0.version)…" } ?? "Check for Updates…"
    }

    // MARK: Check

    private static func check(userInitiated: Bool) async {
        let release: Release?
        do {
            release = try await latestRelease()
        } catch {
            if userInitiated { present(title: "Couldn't check for updates", message: error.localizedDescription) }
            return
        }
        let newer = release.flatMap { isNewer($0.version, than: currentVersion) ? $0 : nil }
        report?(newer)
        if let newer {
            await presentUpdate(newer, userInitiated: userInitiated)
        } else if userInitiated {
            let message = release == nil
                ? "AIrail \(currentVersion) — no newer release found."
                : "AIrail \(currentVersion) is the latest version."
            present(title: "You're up to date", message: message)
        }
    }

    static var currentVersion: String { BuildInfo.version }

    /// The one request in the app that isn't a connected tool's usage check;
    /// it rides the same allowlisted session as those.
    static var latestReleaseURL: URL { URL(string: "https://api.github.com/repos/\(repo)/releases/latest")! }

    private static func latestRelease() async throws -> Release? {
        let response = try await HTTPClient.get(latestReleaseURL, headers: ["Accept": "application/vnd.github+json"])
        // 404 while the repo is private or has no published (non-draft) release.
        guard response.status == 200 else { return nil }
        return try parse(response.data)
    }

    /// The release a `releases/latest` body describes: the tag less its "v",
    /// the first DMG asset, the release page (the listing when it names
    /// none). Nil when it names no tag.
    static func parse(_ data: Data) throws -> Release? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let tag = (json["tag_name"] as? String) ?? ""
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !version.isEmpty else { return nil }

        var dmg: URL?
        for asset in (json["assets"] as? [[String: Any]]) ?? [] {
            if let name = asset["name"] as? String, name.hasSuffix(".dmg"),
               let url = (asset["browser_download_url"] as? String).flatMap(URL.init) {
                dmg = url
                break
            }
        }
        let page = (json["html_url"] as? String).flatMap(URL.init) ?? releasesPage
        return Release(version: version, notes: (json["body"] as? String) ?? "", page: page, dmg: dmg)
    }

    /// Compares dot-separated version numbers (1.10 > 1.9). Non-numeric parts count as 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Presenting

    /// A newer release. The menu path gets the alert it asked for, brought to
    /// the front; the quiet path gets a notification, and the app stays where
    /// it is.
    private static func presentUpdate(_ release: Release, userInitiated: Bool) async {
        guard userInitiated else {
            await announce(release)
            return
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "A new version of AIrail is available"
        var body = "AIrail \(release.version) is available — you have \(currentVersion)."
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            body += "\n\n" + (notes.count > 600 ? String(notes.prefix(600)) + "…" : notes)
        }
        alert.informativeText = body
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(release.dmg ?? release.page)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(release.page)
        default: break
        }
    }

    /// One notification per release version, and only if macOS already lets
    /// AIrail post: a background check never raises the permission prompt
    /// (the Settings toggle does that), and never asked or refused means
    /// nothing — the relabelled menu item carries the news. The version is
    /// remembered only once posted, so a release that couldn't be announced
    /// this check still gets its one notification later.
    private static func announce(_ release: Release) async {
        let defaults = UserDefaults.standard
        guard release.version != defaults.string(forKey: notifiedVersionKey) else { return }
        guard await UsageNotifier.systemAuthorization() else { return }
        do {
            try await UNUserNotificationCenter.current().add(notificationRequest(for: release))
        } catch {
            return // not posted, so not remembered: the next check tries again
        }
        defaults.set(release.version, forKey: notifiedVersionKey)
    }

    private static func present(title: String, message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: Notification

    /// Registered by `AppDelegate` at launch: the notification's Download button.
    static var notificationCategory: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [UNNotificationAction(identifier: downloadActionIdentifier, title: "Download", options: [])],
            intentIdentifiers: []
        )
    }

    /// The quiet path's notification. One identifier, so a newer release
    /// replaces an earlier one in Notification Center rather than stacking;
    /// its own group, apart from the accounts; silent; and it carries its
    /// links, so a click needs nothing fetched (`destination(for:in:)`).
    static func notificationRequest(for release: Release, current: String = currentVersion) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "A new version of AIrail is available"
        content.body = "AIrail \(release.version) is available — you have \(current)."
        content.sound = nil
        content.categoryIdentifier = categoryIdentifier
        content.threadIdentifier = categoryIdentifier
        var userInfo = ["version": release.version, "page": release.page.absoluteString]
        userInfo["dmg"] = release.dmg?.absoluteString
        content.userInfo = userInfo
        return UNNotificationRequest(identifier: categoryIdentifier, content: content, trigger: nil)
    }

    /// Where a response to that notification goes: the Download button to
    /// the DMG — only ever one served from github.com — and anything else,
    /// a plain click included, to the release page and its notes. Dismissing
    /// it goes nowhere.
    nonisolated static func destination(for actionIdentifier: String, in userInfo: [AnyHashable: Any]) -> URL? {
        guard actionIdentifier != UNNotificationDismissActionIdentifier else { return nil }
        let page = (userInfo["page"] as? String).flatMap(URL.init)
        guard actionIdentifier == downloadActionIdentifier,
              let dmg = (userInfo["dmg"] as? String).flatMap(URL.init),
              dmg.scheme?.lowercased() == "https",
              dmg.host()?.lowercased() == "github.com"
        else { return page }
        return dmg
    }
}
