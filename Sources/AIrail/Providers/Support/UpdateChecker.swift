import AppKit

/// A lightweight "is there a newer release?" check against the project's GitHub
/// releases. It notifies and hands off the download — it does not replace the
/// app in place (that's Sparkle's job, added when the repo goes public and the
/// app is notarized). Works the moment the repo/releases are public; while the
/// repo is private the API returns 404 and a manual check just says so.
@MainActor
enum UpdateChecker {
    static let repo = "Vincentj88-python/AIrail"
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }

    private static let lastCheckKey = "lastUpdateCheck"
    private static let minInterval: TimeInterval = 24 * 3600

    struct Release {
        let version: String
        let notes: String
        let page: URL
        let dmg: URL?
    }

    // MARK: Entry points

    /// The "Check for Updates…" menu item. Always reports back to the user.
    static func checkForUpdates() {
        Task { await check(userInitiated: true) }
    }

    /// A quiet check at launch, at most once a day, that only speaks up when
    /// there's actually a newer version.
    static func checkInBackgroundIfDue() {
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
        if let last, Date().timeIntervalSince(last) < minInterval { return }
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        Task { await check(userInitiated: false) }
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
        guard let release else {
            if userInitiated {
                present(title: "You're up to date", message: "AIrail \(currentVersion) — no newer release found.")
            }
            return
        }
        if isNewer(release.version, than: currentVersion) {
            presentUpdate(release)
        } else if userInitiated {
            present(title: "You're up to date", message: "AIrail \(currentVersion) is the latest version.")
        }
    }

    static var currentVersion: String { BuildInfo.version }

    /// The one request in the app that isn't a connected tool's usage check;
    /// it rides the same allowlisted session as those.
    static var latestReleaseURL: URL { URL(string: "https://api.github.com/repos/\(repo)/releases/latest")! }

    private static func latestRelease() async throws -> Release? {
        let response = try await HTTPClient.get(latestReleaseURL, headers: ["Accept": "application/vnd.github+json"])
        // 404 while the repo is private or has no published (non-draft) release.
        guard response.status == 200,
              let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        else { return nil }

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

    // MARK: Alerts

    private static func presentUpdate(_ release: Release) {
        NSApp.activate(ignoringOtherApps: true)
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

    private static func present(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
