import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// The standard About panel, and the two ways to hand over what AIrail knows
/// about itself when something is wrong — both starting from a redacted
/// summary the user sees first. Nothing leaves the Mac by itself: Report a
/// Problem opens a prefilled issue in the browser, Save Diagnostics writes a
/// file where the user chooses.
enum Diagnostics {
    static let repository = "Vincentj88-python/AIrail"

    // MARK: About

    @MainActor
    static func showAbout() {
        let credits = NSMutableAttributedString(
            string: "A screen-edge rail for the AI coding tools you actually run.\n",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor]
        )
        credits.append(NSAttributedString(
            string: "github.com/\(repository)",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .link: URL(string: "https://github.com/\(repository)")!,
            ]
        ))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationVersion: BuildInfo.label,
        ])
    }

    // MARK: Summary

    /// What a bug report needs and nothing it doesn't: the build, the OS,
    /// where the rail is, the displays, and each connected account's state.
    /// Never an email, a key, a project name or a home path.
    @MainActor
    static func summary(manager: ProviderManager, settings: AppSettings, now: Date = Date()) -> String {
        var lines: [String] = []
        lines.append("AIrail \(BuildInfo.label)")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Placement: \(settings.position.label), display \(settings.railDisplay == ScreenSelection.automatic ? "automatic" : "chosen"), refresh every \(Int(settings.refreshInterval)) s")
        for screen in NSScreen.screens {
            let size = "\(Int(screen.frame.width))×\(Int(screen.frame.height))"
            lines.append("Display: \(screen.localizedName) \(size)\(NotchGeometry.hasNotch(screen) ? " (notch)" : "") @\(Int(screen.backingScaleFactor))x")
        }
        lines.append("Network: \(manager.isOnline ? "online" : "offline")")
        let accounts = manager.accountDiagnostics(now: now)
        lines.append(accounts.isEmpty ? "Accounts: none connected" : "Accounts:")
        lines.append(contentsOf: accounts.map { "  " + $0 })
        return redact(lines.joined(separator: "\n"))
    }

    /// The summary, this launch's log entries, and the newest crash report,
    /// all through `redact`.
    @MainActor
    static func report(manager: ProviderManager, settings: AppSettings) async -> String {
        var sections = [summary(manager: manager, settings: settings)]
        sections.append("Log (this launch):\n" + (await logEntries()))
        if let crash = newestCrashReport() {
            sections.append("Newest crash report (\(crash.name)):\n" + crash.text)
        }
        return redact(sections.joined(separator: "\n\n"))
    }

    /// Everything AIrail logged since launch, oldest first. Interpolations
    /// not marked public already read as `<private>` here.
    static func logEntries() async -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(matching: NSPredicate(format: "subsystem == %@", Log.subsystem))
            let formatter = ISO8601DateFormatter()
            let lines = entries.compactMap { $0 as? OSLogEntryLog }.map {
                "\(formatter.string(from: $0.date)) [\($0.category)] \($0.composedMessage)"
            }
            return lines.isEmpty ? "(nothing logged)" : lines.joined(separator: "\n")
        } catch {
            return "(log unavailable: \(error.localizedDescription))"
        }
    }

    /// The newest AIrail crash report in ~/Library/Logs/DiagnosticReports, if any.
    static func newestCrashReport(limit: Int = 200) -> (name: String, text: String)? {
        let directory = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/DiagnosticReports")
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let reports = urls.filter { $0.lastPathComponent.hasPrefix("AIrail") && ["ips", "crash"].contains($0.pathExtension) }
        let newest = reports.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
        guard let newest, let text = try? String(contentsOf: newest, encoding: .utf8) else { return nil }
        return (newest.lastPathComponent, text.split(separator: "\n", omittingEmptySubsequences: false).prefix(limit).joined(separator: "\n"))
    }

    // MARK: Redaction

    /// The home folder becomes "~", anything shaped like an email becomes
    /// "<email>", and any long token-shaped run becomes "<redacted>".
    static func redact(_ text: String, home: String = NSHomeDirectory()) -> String {
        var out = text.replacingOccurrences(of: home, with: "~")
        if let user = home.split(separator: "/").last {
            out = out.replacingOccurrences(of: "/Users/\(user)", with: "~")
        }
        out = out.replacingOccurrences(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, with: "<email>", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\b(?:sk|gho|ghp|ghu|eyJ)[A-Za-z0-9_\-\.]{20,}"#, with: "<redacted>", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\b[A-Za-z0-9_\-]{48,}\b"#, with: "<redacted>", options: .regularExpression)
        return out
    }

    // MARK: Report a Problem

    /// A Feedback Assistant-style sheet: the redacted summary, readable and
    /// selectable, with the two ways to hand it over.
    @MainActor
    static func reportProblem(manager: ProviderManager, settings: AppSettings) {
        let summary = summary(manager: manager, settings: settings)
        let alert = NSAlert()
        alert.messageText = "Report a Problem"
        alert.informativeText = "This is everything AIrail would include. Nothing is sent until you open the issue or save the file; add what went wrong on the page."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 180))
        let textView = NSTextView(frame: scroll.bounds)
        textView.string = summary
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Open GitHub Issue")
        alert.addButton(withTitle: "Save Diagnostics…")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(issueURL(summary: summary))
        case .alertSecondButtonReturn:
            Task { await saveReport(manager: manager, settings: settings) }
        default:
            break
        }
    }

    /// A new issue from the bug form, its diagnostics field prefilled with
    /// the summary (GitHub fills form fields from query parameters by id).
    static func issueURL(summary: String) -> URL {
        var components = URLComponents(string: "https://github.com/\(repository)/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "template", value: "bug.yml"),
            URLQueryItem(name: "diagnostics", value: summary),
        ]
        return components.url ?? URL(string: "https://github.com/\(repository)/issues/new")!
    }

    // MARK: Save Diagnostics

    @MainActor
    static func saveReport(manager: ProviderManager, settings: AppSettings) async {
        let text = await report(manager: manager, settings: settings)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "AIrail Diagnostics \(Date().formatted(.iso8601.year().month().day())).txt"
        panel.title = "Save Diagnostics"
        panel.message = "A redacted summary, this launch's log and the newest crash report, if any."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.window.error("saving diagnostics failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
