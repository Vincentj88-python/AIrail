import Foundation
import SwiftUI

@MainActor
final class CopilotProvider: UsageProviding {
    let id = "copilot"
    let displayName = "Copilot"
    let color = Color(hex: 0x9CA3AF)
    let symbolName = "cpu"
    let brandIconPath: String? = BrandIcons.copilot

    let connection = ConnectionMethod(
        toolName: "GitHub CLI",
        summary: "Uses your GitHub CLI sign-in",
        explainer: "AIrail asks the GitHub CLI (gh) for the token it is signed in with and uses it to read your Copilot quota from GitHub — AI credits (or premium requests on a legacy plan) used this month, your plan, and when the quota resets. If gh isn't installed, the Copilot editor extension's saved sign-in is used instead. Nothing is written back."
    )

    let demoProfile = MockUsageEngine.Profile(
        plan: "Pro", sessionStart: 18, weeklyLimit: 300, weeklyStart: 22,
        credits: nil, spend: nil, spendCap: nil,
        demoModels: ["gpt-5.5", "claude-sonnet-5"]
    )

    static let quotaURL = URL(string: "https://api.github.com/copilot_internal/user")!
    private static let extensionAppsPath = NSHomeDirectory() + "/.config/github-copilot/apps.json"

    private var token: String?

    func isInstalled() -> Bool {
        InstallDetection.onPath("gh")
            || InstallDetection.anyExists([".config/github-copilot", "Library/Application Support/GitHub Copilot"])
    }

    func fetchUsage() async throws -> UsageSnapshot {
        let token = try await loadToken()
        let data: Data
        do {
            data = try await HTTPClient.authorizedGet(
                Self.quotaURL,
                headers: ["Authorization": "token \(token)", "Accept": "application/json"],
                tool: connection.toolName
            )
        } catch ConnectionError.expired(let tool) {
            self.token = nil
            throw ConnectionError.expired(tool: tool)
        }
        let report = try CopilotUsage.parse(data)
        return CopilotUsage.snapshot(report: report, providerId: id, displayName: displayName)
    }

    private func loadToken() async throws -> String {
        if let token { return token }
        let fresh: String
        if let gh = CommandRunner.locate("gh") {
            let result = try await CommandRunner.run(gh, arguments: ["auth", "token"])
            guard result.exitCode == 0, !result.stdout.isEmpty else {
                throw ConnectionError.notSignedIn(tool: connection.toolName)
            }
            fresh = result.stdout
        } else if let data = FileManager.default.contents(atPath: Self.extensionAppsPath),
                  let saved = CopilotUsage.extensionToken(from: data) {
            fresh = saved
        } else {
            throw ConnectionError.notInstalled(tool: connection.toolName)
        }
        token = fresh
        return fresh
    }
}

enum CopilotUsage {
    struct Report: Sendable {
        var plan: String?
        var login: String?
        /// "credits" on a credits-billed plan, "premium" on a legacy
        /// premium-request plan, "chat" when there is neither.
        var meter: String
        var used: Double?
        var limit: Double?
        var percentUsed: Double
        var unlimited: Bool
        var resetsAt: Date?
        /// Every meter GitHub reports, for the overlay's meter list.
        var meters: [UsageMeter] = []
    }

    /// `apps.json` from the editor extension: `{"github.com:<client>": {"user": …, "oauth_token": …}}`.
    static func extensionToken(from data: Data) -> String? {
        guard let json = try? JSONObject(data: data) else { return nil }
        for key in json.raw.keys.sorted() where key.hasPrefix("github.com") {
            if let token = json[key]?.string("oauth_token"), !token.isEmpty {
                return token
            }
        }
        return nil
    }

    /// `quota_snapshots` has one meter per feature. The premium pool is the
    /// one people run out of — since June 2026 it is billed as AI credits
    /// (1 credit = $0.01) on monthly plans, which the endpoint flags with
    /// `token_based_billing`; annual plans that stayed on premium requests
    /// keep the old shape. Plans without any premium pool fall back to chat.
    /// A `-1` entitlement is GitHub's "unlimited" sentinel on paid plans.
    static func parse(_ data: Data, locale: Locale = .autoupdatingCurrent) throws -> Report {
        let json = try JSONObject(data: data)
        guard let snapshots = json["quota_snapshots"] else {
            throw ConnectionError.shapeChanged(tool: "GitHub", detail: json.keyNames)
        }
        let premium = snapshots["premium_interactions"]
        let hasPremium = premium.map { isUnlimited($0) || ($0.double("entitlement") ?? 0) > 0 } ?? false
        let meterName = hasPremium ? "premium_interactions" : "chat"
        guard let meter = snapshots[meterName] else {
            throw ConnectionError.shapeChanged(tool: "GitHub", detail: snapshots.keyNames)
        }
        let creditsBilled = hasPremium
            && (json.bool("token_based_billing") == true || premium?.bool("token_based_billing") == true)
        let unlimited = isUnlimited(meter)
        let entitlement = meter.double("entitlement")
        let remaining = meter.double("remaining")
        let percentRemaining = meter.double("percent_remaining") ?? (unlimited ? 100 : 0)
        let meters: [UsageMeter] = [
            ("premium_interactions", creditsBilled ? "AI credits" : "Premium requests"),
            ("chat", "Chat"),
            ("completions", "Completions"),
        ].compactMap { key, label in
            guard let quota = snapshots[key] else { return nil }
            let isUnlimited = isUnlimited(quota)
            let entitlement = quota.double("entitlement") ?? 0
            guard isUnlimited || entitlement > 0 else { return nil }
            let remaining = quota.double("remaining") ?? 0
            let used = max(0, entitlement - remaining)
            return UsageMeter(
                name: label,
                percent: isUnlimited ? nil : UsageSnapshot.clampPercent(100 - (quota.double("percent_remaining") ?? 0)),
                used: isUnlimited ? nil : used,
                limit: isUnlimited ? nil : entitlement,
                note: isUnlimited ? "Unlimited"
                    : (creditsBilled && key == "premium_interactions"
                       ? creditsNote(used: used, entitlement: entitlement, overage: quota.double("overage_count"), locale: locale)
                       : nil)
            )
        }
        return Report(
            plan: planLabel(json.string("copilot_plan")),
            login: json.string("login"),
            meter: meterName == "chat" ? "chat" : (creditsBilled ? "credits" : "premium"),
            used: unlimited ? nil : zip(entitlement, remaining).map { max(0, $0 - $1) },
            limit: unlimited ? nil : entitlement,
            percentUsed: UsageSnapshot.clampPercent(100 - percentRemaining),
            unlimited: unlimited,
            resetsAt: DateParsing.iso8601(json.string("quota_reset_date_utc"))
                ?? DateParsing.day(json.string("quota_reset_date")),
            meters: meters
        )
    }

    private static func isUnlimited(_ quota: JSONObject) -> Bool {
        quota.bool("unlimited") == true || (quota.double("entitlement") ?? 0) < 0
    }

    /// "1 credit = $0.01 · ≈ $9.23 of $15.00", plus "· 120 over plan" once
    /// the pool is exhausted — only what GitHub states, never a flex figure.
    static func creditsNote(used: Double, entitlement: Double, overage: Double?, locale: Locale = .autoupdatingCurrent) -> String {
        var note = "1 credit = \(UsageFormatting.dollars(0.01, locale: locale)) · ≈ "
            + "\(UsageFormatting.dollars(used / 100, locale: locale)) of \(UsageFormatting.dollars(entitlement / 100, locale: locale))"
        if let overage, overage > 0 {
            note += " · \(Int(overage).formatted(.number.locale(locale))) over plan"
        }
        return note
    }

    static func planLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw {
        case "pro_plus": return "Pro+"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func snapshot(report: Report, providerId: String, displayName: String, now: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(
            providerId: providerId,
            displayName: displayName,
            sessionPercent: nil,
            weeklyUsed: report.used,
            weeklyLimit: report.limit,
            weeklyPercent: report.unlimited ? nil : report.percentUsed,
            resetsAt: nil,
            credits: nil,
            spend: nil,
            spendCap: nil,
            plan: report.plan,
            status: .ok,
            lastUpdated: now,
            periodLabel: report.meter == "chat" ? "monthly chat" : (report.meter == "credits" ? "monthly" : "monthly premium"),
            unitLabel: report.meter == "credits" ? "AI credits" : "requests",
            weeklyResetsAt: report.resetsAt,
            // The pool is monthly: it began one calendar month before it resets.
            periodStartsAt: report.resetsAt.flatMap { Calendar.current.date(byAdding: .month, value: -1, to: $0) },
            account: report.login,
            detail: UsageDetail(meters: report.meters)
        )
    }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
