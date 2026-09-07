import CryptoKit
import Foundation
import SwiftUI

@MainActor
final class ClaudeProvider: UsageProviding {
    let id = "claude"
    let displayName = "Claude"
    let color = Color(hex: 0xF97316)
    let symbolName = "sparkles"
    let brandIconPath: String? = BrandIcons.claude

    let connection = ConnectionMethod(
        toolName: "Claude Code",
        summary: "Uses your Claude Code sign-in",
        explainer: "AIrail reads the sign-in Claude Code keeps in your Keychain and asks Anthropic for your plan's current 5-hour and weekly limits — the same numbers Claude Code's /usage shows. Your local session transcripts in ~/.claude provide the 24-hour and 7-day charts, the by-model and by-project breakdown, and the tool counts. Nothing is written back, and the refresh token is never used.",
        caveat: "macOS asks before AIrail can read the Keychain item. Choose “Always Allow” so it stops asking; it may ask again after Claude Code renews its sign-in. If Claude Code runs with CLAUDE_CONFIG_DIR pointing somewhere other than ~/.claude, AIrail can't see that shell setting and may not find the item."
    )

    let demoProfile = MockUsageEngine.Profile(
        plan: "Max", sessionStart: 41, weeklyLimit: 480, weeklyStart: 47,
        credits: nil, spend: nil, spendCap: nil,
        demoModels: ["claude-opus-5", "claude-sonnet-5"]
    )

    /// The Keychain item the sign-in was last found under; nil until the first read.
    private var keychainService: String?
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private var credential: ClaudeUsage.Credential?
    private let scanner = TranscriptScanner(
        roots: [URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")],
        requiredSubstrings: ["\"assistant\""],
        extractor: ClaudeUsage.transcriptEvent
    )

    func isInstalled() -> Bool {
        InstallDetection.anyExists([".claude", "Library/Application Support/Claude"])
    }

    func fetchUsage() async throws -> UsageSnapshot {
        let credential = try await loadCredential()
        let data: Data
        do {
            data = try await HTTPClient.authorizedGet(
                Self.usageURL,
                headers: [
                    "Authorization": "Bearer \(credential.accessToken)",
                    "anthropic-beta": "oauth-2025-04-20",
                    "Accept": "application/json",
                ],
                tool: connection.toolName
            )
        } catch ConnectionError.expired(let tool) {
            self.credential = nil // Claude Code may have renewed it; re-read next time
            throw ConnectionError.expired(tool: tool)
        }
        let report = try ClaudeUsage.parse(data)
        let transcripts = try? await scanner.summary()
        return ClaudeUsage.snapshot(
            report: report, credential: credential, transcripts: transcripts,
            providerId: id, displayName: displayName
        )
    }

    /// The Keychain read is the consent moment (macOS prompts), so the token is
    /// kept in memory and only re-read once it has expired. The read happens
    /// off the main thread so the rail keeps animating while the prompt is up.
    private func loadCredential() async throws -> ClaudeUsage.Credential {
        if let credential, let expiresAt = credential.expiresAt, expiresAt > Date().addingTimeInterval(60) {
            return credential
        }
        let tool = connection.toolName
        let known = keychainService
        let candidates = ClaudeUsage.keychainServices()
        let (service, data) = try await Task.detached { () throws -> (String, Data) in
            if let known {
                do {
                    return (known, try KeychainReader.genericPassword(service: known, tool: tool))
                } catch ConnectionError.notSignedIn {
                    // Renamed or removed since: look at every candidate again.
                }
            }
            return try KeychainReader.genericPassword(services: candidates, tool: tool)
        }.value
        keychainService = service
        let fresh = try ClaudeUsage.credential(from: data)
        if let expiresAt = fresh.expiresAt, expiresAt < Date() {
            throw ConnectionError.expired(tool: connection.toolName)
        }
        credential = fresh
        return fresh
    }
}

/// Pure parsing for the Claude provider, kept separate so fixtures can test it.
enum ClaudeUsage {
    struct Credential: Sendable {
        let accessToken: String
        let expiresAt: Date?
        let plan: String?
    }

    struct Report: Sendable {
        var sessionPercent: Double?
        var sessionResetsAt: Date?
        var weeklyPercent: Double?
        var weeklyResetsAt: Date?
        var extraSpend: Double?
        var extraCap: Double?
    }

    /// The Keychain items Claude Code may keep its sign-in under. The plain
    /// name is the default; with CLAUDE_CONFIG_DIR set, Claude Code appends
    /// "-" and the first eight hex digits of SHA-256 over the NFC-normalised
    /// path, verbatim. A launchd-spawned app never sees a shell export, so the
    /// default folder's hash (the common `export CLAUDE_CONFIG_DIR=$HOME/.claude`)
    /// is guessed alongside any value in AIrail's own environment.
    static func keychainServices(
        home: String = NSHomeDirectory(),
        configDir: String? = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
    ) -> [String] {
        let base = "Claude Code-credentials"
        var paths = [home + "/.claude"]
        if let configDir, !configDir.isEmpty { paths.append(configDir) }
        var names = [base]
        for path in paths {
            let normalized = path.precomposedStringWithCanonicalMapping
            let hex = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
            let name = base + "-" + hex.prefix(8)
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// The Keychain item is JSON: `{"claudeAiOauth": {"accessToken": …, "expiresAt": <ms>, "subscriptionType": "max"}}`.
    static func credential(from data: Data) throws -> Credential {
        guard let oauth = try JSONObject(data: data)["claudeAiOauth"],
              let token = oauth.string("accessToken"), !token.isEmpty
        else { throw ConnectionError.notSignedIn(tool: "Claude Code") }
        return Credential(
            accessToken: token,
            expiresAt: oauth.double("expiresAt").map { Date(timeIntervalSince1970: $0 / 1000) },
            plan: planLabel(oauth.string("subscriptionType"))
        )
    }

    static func parse(_ data: Data) throws -> Report {
        let json = try JSONObject(data: data)
        var report = Report()
        if let session = json["five_hour"] {
            report.sessionPercent = session.double("utilization")
            report.sessionResetsAt = DateParsing.iso8601(session.string("resets_at"))
        }
        if let weekly = json["seven_day"] {
            report.weeklyPercent = weekly.double("utilization")
            report.weeklyResetsAt = DateParsing.iso8601(weekly.string("resets_at"))
        }
        // Pay-as-you-go top-up on top of the plan; amounts are in minor units.
        if let extra = json["extra_usage"], extra.bool("is_enabled") == true {
            let scale = pow(10, extra.double("decimal_places") ?? 2)
            report.extraSpend = extra.double("used_credits").map { $0 / scale }
            report.extraCap = extra.double("monthly_limit").map { $0 / scale }
        }
        guard report.sessionPercent != nil || report.weeklyPercent != nil else {
            throw ConnectionError.unreadable("no usage windows in response")
        }
        return report
    }

    static func planLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// One transcript line: `{"type":"assistant","timestamp":…,"requestId":…,"cwd":…,"sessionId":…,
    /// "message":{"id":…,"model":…,"usage":{…},"content":[{"type":"tool_use","name":…}]}}`.
    /// A streamed message is written once per content block with the same
    /// usage; `message.id` + `requestId` dedups the tokens, tool calls still all count.
    static let transcriptEvent: TranscriptScanner.Extractor = { line, _ in
        guard line.string("type") == "assistant",
              let date = DateParsing.iso8601(line.string("timestamp")),
              let message = line["message"]
        else { return nil }
        var event = TranscriptEvent(date: date)
        if let usage = message["usage"] {
            event.tokens = TokenSplit(
                input: usage.double("input_tokens") ?? 0,
                output: usage.double("output_tokens") ?? 0,
                cacheWrite: usage.double("cache_creation_input_tokens") ?? 0,
                cacheRead: usage.double("cache_read_input_tokens") ?? 0
            )
            event.thinking = usage["output_tokens_details"]?.double("thinking_tokens") ?? 0
        } else {
            event.countsAsMessage = false
        }
        if let model = message.string("model"), !model.hasPrefix("<") {
            event.model = model
        }
        event.project = line.string("cwd").map { ($0 as NSString).lastPathComponent }
        event.session = line.string("sessionId")
        event.toolCalls = message.array("content")
            .filter { $0.string("type") == "tool_use" }
            .compactMap { $0.string("name") }
        let key = [message.string("id"), line.string("requestId")].compactMap { $0 }.joined(separator: ":")
        event.dedupKey = key.isEmpty ? nil : key
        return event
    }

    static func snapshot(
        report: Report, credential: Credential, transcripts: TranscriptScanner.Summary?,
        providerId: String, displayName: String, now: Date = Date()
    ) -> UsageSnapshot {
        var detail = UsageDetail()
        if let transcripts {
            detail = UsageDetail(hours: transcripts.hours, days: transcripts.days, week: transcripts.week)
        }
        return UsageSnapshot(
            providerId: providerId,
            displayName: displayName,
            sessionPercent: report.sessionPercent.map(UsageSnapshot.clampPercent),
            weeklyUsed: nil,
            weeklyLimit: nil,
            weeklyPercent: report.weeklyPercent.map(UsageSnapshot.clampPercent),
            resetsAt: report.sessionResetsAt,
            credits: nil,
            spend: report.extraSpend,
            spendCap: report.extraCap,
            // Extra usage runs with the subscription's billing month, not the calendar one.
            spendPeriod: .billingCycle,
            plan: credential.plan,
            status: .ok,
            lastUpdated: now,
            weeklyResetsAt: report.weeklyResetsAt,
            sessionWindowLength: 5 * 3600, // the response key is five_hour; the length is in its name
            periodStartsAt: report.weeklyResetsAt?.addingTimeInterval(-7 * 24 * 3600),
            detail: detail
        )
    }
}
