import Foundation
import SwiftUI

/// One OpenAI account: Codex and ChatGPT share it, and only Codex exposes
/// usage limits, so this provider stands in for both.
@MainActor
final class CodexProvider: UsageProviding {
    let id = "codex"
    let displayName = "Codex"
    let color = Color(hex: 0xA855F7)
    let symbolName = "terminal"

    let connection = ConnectionMethod(
        toolName: "Codex",
        summary: "Uses your Codex sign-in · covers ChatGPT too",
        explainer: "AIrail reads the sign-in Codex keeps in ~/.codex and asks OpenAI for your plan's current 5-hour and weekly limits. Your local Codex sessions provide the 24-hour and 7-day charts, the by-model and by-project breakdown, and the tool counts. Nothing is written back.",
        caveat: "ChatGPT and Codex share one OpenAI account, and ChatGPT itself doesn't publish usage limits — so this account shows the Codex limits that come with your ChatGPT plan."
    )

    let demoProfile = MockUsageEngine.Profile(
        plan: "Plus", sessionStart: 33, weeklyLimit: 3000, weeklyStart: 38,
        credits: nil, spend: nil, spendCap: nil,
        demoModels: ["gpt-5.5", "gpt-5.5-mini"]
    )

    private static let home = NSHomeDirectory() + "/.codex"
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private let scanner = TranscriptScanner(
        roots: [URL(fileURLWithPath: home + "/sessions")],
        requiredSubstrings: ["\"token_count\"", "\"session_meta\"", "\"turn_context\"", "\"function_call\"", "\"custom_tool_call\""],
        extractor: CodexUsage.transcriptEvent
    )

    func isInstalled() -> Bool {
        InstallDetection.anyExists([".codex"])
    }

    func fetchUsage() async throws -> UsageSnapshot {
        let credential = try CodexUsage.credential(fromFileAt: Self.home + "/auth.json")
        var headers = [
            "Authorization": "Bearer \(credential.accessToken)",
            "Accept": "application/json",
        ]
        if let accountId = credential.accountId {
            headers["chatgpt-account-id"] = accountId
        }
        let data = try await HTTPClient.authorizedGet(Self.usageURL, headers: headers, tool: connection.toolName)
        let report = try CodexUsage.parse(data)
        let transcripts = try? await scanner.summary()
        return CodexUsage.snapshot(
            report: report, credential: credential, transcripts: transcripts,
            providerId: id, displayName: displayName
        )
    }
}

enum CodexUsage {
    struct Credential: Sendable {
        let accessToken: String
        let accountId: String?
        let email: String?
        let plan: String?
    }

    struct Report: Sendable {
        var sessionPercent: Double?
        var sessionResetsAt: Date?
        var sessionWindowSeconds: TimeInterval?
        var weeklyPercent: Double?
        var weeklyResetsAt: Date?
        var weeklyWindowSeconds: TimeInterval?
        var plan: String?
        var email: String?
        var credits: Double?
    }

    static func credential(fromFileAt path: String) throws -> Credential {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ConnectionError.notSignedIn(tool: "Codex")
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ConnectionError.unreadable("couldn't read auth.json")
        }
        return try credential(from: data)
    }

    /// `~/.codex/auth.json`: `{"tokens": {"access_token", "id_token", "account_id"}, "last_refresh": …}`.
    /// The id token carries the email and plan under OpenAI's claim namespace.
    static func credential(from data: Data) throws -> Credential {
        guard let tokens = try JSONObject(data: data)["tokens"],
              let accessToken = tokens.string("access_token"), !accessToken.isEmpty
        else { throw ConnectionError.notSignedIn(tool: "Codex") }
        let claims = tokens.string("id_token").flatMap(JWT.claims)
        let auth = claims?["https://api.openai.com/auth"]
        return Credential(
            accessToken: accessToken,
            accountId: tokens.string("account_id") ?? auth?.string("chatgpt_account_id"),
            email: claims?.string("email"),
            plan: planLabel(auth?.string("chatgpt_plan_type"))
        )
    }

    /// Windows come as `primary_window` (5 h) and `secondary_window` (7 d);
    /// each says how long it is, so they are told apart by length, not name.
    static func parse(_ data: Data) throws -> Report {
        let json = try JSONObject(data: data)
        guard let limits = json["rate_limit"] else {
            throw ConnectionError.unreadable("no rate limits in response")
        }
        var report = Report()
        for key in ["primary_window", "secondary_window"] {
            guard let window = limits[key], let percent = window.double("used_percent") else { continue }
            let seconds = window.double("limit_window_seconds") ?? 0
            let resetsAt = DateParsing.unixSeconds(window.double("reset_at"))
            if seconds <= 24 * 3600 {
                report.sessionPercent = percent
                report.sessionResetsAt = resetsAt
                report.sessionWindowSeconds = seconds > 0 ? seconds : nil
            } else {
                report.weeklyPercent = percent
                report.weeklyResetsAt = resetsAt
                report.weeklyWindowSeconds = seconds
            }
        }
        guard report.sessionPercent != nil || report.weeklyPercent != nil else {
            throw ConnectionError.unreadable("no usage windows in response")
        }
        report.plan = planLabel(json.string("plan_type"))
        report.email = json.string("email")
        if let credits = json["credits"], credits.bool("has_credits") == true {
            report.credits = credits.double("balance")
        }
        return report
    }

    static func planLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Session lines that matter, in the order a file writes them:
    /// `session_meta` (cwd, id) → `turn_context` (model) → `token_count`
    /// events whose `last_token_usage` is the delta for that request, so
    /// summing it per bucket is exact → `function_call` items (tool names).
    static let transcriptEvent: TranscriptScanner.Extractor = { line, context in
        guard let date = DateParsing.iso8601(line.string("timestamp")),
              let payload = line["payload"]
        else { return nil }
        switch line.string("type") {
        case "session_meta":
            context.session = payload.string("id")
            context.project = payload.string("cwd").map { ($0 as NSString).lastPathComponent }
            return nil
        case "turn_context":
            context.model = payload.string("model")
            return nil
        case "event_msg":
            guard payload.string("type") == "token_count",
                  let usage = payload["info"]?["last_token_usage"]
            else { return nil }
            let input = usage.double("input_tokens") ?? 0
            let cached = usage.double("cached_input_tokens") ?? 0
            var event = TranscriptEvent(date: date)
            event.tokens = TokenSplit(
                input: max(0, input - cached),
                output: usage.double("output_tokens") ?? 0,
                cacheWrite: usage.double("cache_write_input_tokens") ?? 0,
                cacheRead: cached
            )
            event.thinking = usage.double("reasoning_output_tokens") ?? 0
            event.model = context.model
            event.project = context.project
            event.session = context.session
            return event
        case "response_item":
            guard ["function_call", "custom_tool_call"].contains(payload.string("type") ?? ""),
                  let name = payload.string("name")
            else { return nil }
            var event = TranscriptEvent(date: date)
            event.toolCalls = [name]
            event.countsAsMessage = false
            return event
        default:
            return nil
        }
    }

    static func snapshot(
        report: Report, credential: Credential, transcripts: TranscriptScanner.Summary?,
        providerId: String, displayName: String, now: Date = Date()
    ) -> UsageSnapshot {
        var detail = UsageDetail()
        if let transcripts {
            detail = UsageDetail(
                hours: transcripts.hours, days: transcripts.days, week: transcripts.week,
                newestLocalEvent: transcripts.newestEventDate, previousWeek: transcripts.previousWeek
            )
        }
        return UsageSnapshot(
            providerId: providerId,
            displayName: displayName,
            sessionPercent: report.sessionPercent.map(UsageSnapshot.clampPercent),
            weeklyUsed: nil,
            weeklyLimit: nil,
            weeklyPercent: report.weeklyPercent.map(UsageSnapshot.clampPercent),
            resetsAt: report.sessionResetsAt,
            credits: report.credits,
            spend: nil,
            spendCap: nil,
            plan: report.plan ?? credential.plan,
            status: .ok,
            lastUpdated: now,
            weeklyResetsAt: report.weeklyResetsAt,
            sessionWindowLength: report.sessionWindowSeconds,
            periodStartsAt: zip(report.weeklyResetsAt, report.weeklyWindowSeconds).map { $0.addingTimeInterval(-$1) },
            account: report.email ?? credential.email,
            detail: detail
        )
    }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
