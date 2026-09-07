import Foundation
import SwiftUI

@MainActor
final class CursorProvider: UsageProviding {
    let id = "cursor"
    let displayName = "Cursor"
    let color = Color(hex: 0x3B82F6)
    let symbolName = "chevron.left.forwardslash.chevron.right"
    let brandIconPath: String? = BrandIcons.cursor

    let connection = ConnectionMethod(
        toolName: "Cursor",
        summary: "Uses the sign-in Cursor stores on this Mac",
        explainer: "Cursor has no public usage API. AIrail reads the sign-in Cursor keeps in its local database and asks cursor.com for your usage the same way Cursor's own dashboard does — how much of your included usage this billing cycle is spent, your plan, when the cycle resets, and the per-request history behind the charts and model breakdown. Nothing is written back.",
        caveat: "This depends on Cursor's internals, and a Cursor update can break it without warning. If that happens AIrail shows a stale or error badge rather than guessing."
    )

    let demoProfile = MockUsageEngine.Profile(
        plan: "Pro", sessionStart: 62, weeklyLimit: 2000, weeklyStart: 62,
        credits: 8760, spend: 18.40, spendCap: 60, spendPeriod: .billingCycle,
        demoModels: ["claude-opus-5", "gpt-5.5", "cursor-grok-4.6-high-fast"]
    )

    private static let databasePath = NSHomeDirectory()
        + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    static let usageURL = URL(string: "https://cursor.com/api/usage-summary")!
    static let eventsURL = URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!
    /// Two weeks of events are kept: the week on the chart and the one before it.
    private static let historyDays = 14

    private var credential: CursorUsage.Credential?
    /// Per-request events for the last week, oldest first. Refreshes only
    /// fetch what is newer than the last one seen.
    private var events: [CursorUsage.Event] = []

    func isInstalled() -> Bool {
        InstallDetection.anyExists([".cursor", "Library/Application Support/Cursor"])
    }

    func fetchUsage() async throws -> UsageSnapshot {
        let credential = try await loadCredential()
        let headers = [
            "Cookie": credential.sessionCookie,
            "Accept": "application/json",
            "Origin": "https://cursor.com",
        ]
        let data: Data
        do {
            data = try await HTTPClient.authorizedGet(Self.usageURL, headers: headers, tool: connection.toolName)
        } catch ConnectionError.expired(let tool) {
            self.credential = nil
            throw ConnectionError.expired(tool: tool)
        }
        let report = try CursorUsage.parse(data)
        // History is a bonus on top of the headline numbers: a failure here
        // keeps whatever was fetched before rather than failing the account.
        try? await refreshEvents(headers: headers)
        let detail = CursorUsage.detail(events: events, report: report, days: Self.historyDays)
        return CursorUsage.snapshot(
            report: report, credential: credential, detail: detail,
            providerId: id, displayName: displayName
        )
    }

    private func refreshEvents(headers: [String: String]) async throws {
        let now = Date()
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.historyDays, to: now) ?? now
        events.removeAll { $0.date < cutoff }
        let since = events.last.map { $0.date.addingTimeInterval(0.001) } ?? cutoff
        var fetched: [CursorUsage.Event] = []
        var page = 1
        while true {
            let body: [String: Any] = [
                "teamId": 0,
                "startDate": String(Int(since.timeIntervalSince1970 * 1000)),
                "endDate": String(Int(now.timeIntervalSince1970 * 1000)),
                "page": page,
                "pageSize": 1000,
            ]
            let data = try await HTTPClient.authorizedPost(Self.eventsURL, headers: headers, body: body, tool: connection.toolName)
            let batch = try CursorUsage.parseEvents(data)
            fetched += batch.events
            if fetched.count >= batch.total || batch.events.isEmpty || page >= 10 { break }
            page += 1
        }
        let known = Set(events.map(\.id))
        events += fetched.filter { !known.contains($0.id) }
        events.sort { $0.date < $1.date }
    }

    /// The token lives in a database Cursor keeps open; reading it (and, if
    /// needed, copying it) stays off the main thread.
    private func loadCredential() async throws -> CursorUsage.Credential {
        if let credential, credential.expiresAt.map({ $0 > Date().addingTimeInterval(60) }) ?? true {
            return credential
        }
        guard FileManager.default.fileExists(atPath: Self.databasePath) else {
            throw ConnectionError.notInstalled(tool: connection.toolName)
        }
        let path = Self.databasePath
        let stored = try await Task.detached { () throws -> [String: String] in
            var values: [String: String] = [:]
            for key in ["accessToken", "cachedEmail", "stripeMembershipType"] {
                values[key] = try SQLiteReader.itemTableValue(databasePath: path, key: "cursorAuth/" + key)
            }
            return values
        }.value
        guard let token = stored["accessToken"], !token.isEmpty else {
            throw ConnectionError.notSignedIn(tool: connection.toolName)
        }
        let fresh = try CursorUsage.credential(
            accessToken: token,
            email: stored["cachedEmail"],
            membership: stored["stripeMembershipType"]
        )
        if let expiresAt = fresh.expiresAt, expiresAt < Date() {
            throw ConnectionError.expired(tool: connection.toolName)
        }
        credential = fresh
        return fresh
    }
}

enum CursorUsage {
    struct Credential: Sendable {
        let userId: String
        let accessToken: String
        let expiresAt: Date?
        let email: String?
        let plan: String?

        /// cursor.com identifies the browser session as `<userId>::<token>`.
        var sessionCookie: String {
            "WorkosCursorSessionToken=\(userId)%3A%3A\(accessToken)"
        }
    }

    struct Report: Sendable {
        var percentUsed: Double?
        var autoPercentUsed: Double?
        var apiPercentUsed: Double?
        var autoMessage: String?
        var apiMessage: String?
        var cycleStart: Date?
        var cycleEnd: Date?
        var plan: String?
    }

    /// One request from the dashboard's usage-events feed.
    struct Event: Sendable, Identifiable, Equatable {
        let id: String
        let date: Date
        let model: String
        let tokens: TokenSplit
        let cents: Double
        let conversation: String?
    }

    struct EventPage: Sendable {
        let events: [Event]
        let total: Int
    }

    /// The token is a JWT whose `sub` is `auth0|user_…`; the part after the bar is the user id.
    static func credential(accessToken: String, email: String?, membership: String?) throws -> Credential {
        guard let claims = JWT.claims(accessToken), let subject = claims.string("sub") else {
            throw ConnectionError.unreadable("unrecognized Cursor token")
        }
        let userId = subject.split(separator: "|").last.map(String.init) ?? subject
        return Credential(
            userId: userId,
            accessToken: accessToken,
            expiresAt: DateParsing.unixSeconds(claims.double("exp")),
            email: email,
            plan: planLabel(membership)
        )
    }

    /// `usage-summary`: `{"billingCycleEnd": …, "membershipType": …, "individualUsage": {"plan": {"totalPercentUsed": …,
    /// "autoPercentUsed": …, "apiPercentUsed": …}, "onDemand": {"enabled": …}}, "autoModelSelectedDisplayMessage": …}`.
    /// Only percentages are shown — the raw used/limit figures are in units
    /// Cursor doesn't document, and the percent is what its dashboard states.
    static func parse(_ data: Data) throws -> Report {
        let json = try JSONObject(data: data)
        guard let usage = json["individualUsage"], let plan = usage["plan"] else {
            throw ConnectionError.unreadable("no plan usage in response")
        }
        let unlimited = json.bool("isUnlimited") ?? false
        return Report(
            percentUsed: unlimited ? nil : plan.double("totalPercentUsed").map(UsageSnapshot.clampPercent),
            autoPercentUsed: unlimited ? nil : plan.double("autoPercentUsed").map(UsageSnapshot.clampPercent),
            apiPercentUsed: unlimited ? nil : plan.double("apiPercentUsed").map(UsageSnapshot.clampPercent),
            autoMessage: json.string("autoModelSelectedDisplayMessage"),
            apiMessage: json.string("namedModelSelectedDisplayMessage"),
            cycleStart: DateParsing.iso8601(json.string("billingCycleStart")),
            cycleEnd: DateParsing.iso8601(json.string("billingCycleEnd")),
            plan: planLabel(json.string("membershipType"))
        )
    }

    /// `get-filtered-usage-events`: `{"totalUsageEventsCount": N, "usageEventsDisplay": [{"timestamp": "<ms>",
    /// "model": …, "tokenUsage": {"inputTokens", "outputTokens", "cacheWriteTokens", "cacheReadTokens", "totalCents"},
    /// "conversationId": …}]}`. Calls without `tokenUsage` still count as requests.
    static func parseEvents(_ data: Data) throws -> EventPage {
        let json = try JSONObject(data: data)
        let events: [Event] = json.array("usageEventsDisplay").compactMap { item in
            guard let millis = item.double("timestamp"), let model = item.string("model") else { return nil }
            let usage = item["tokenUsage"]
            let tokens = TokenSplit(
                input: usage?.double("inputTokens") ?? 0,
                output: usage?.double("outputTokens") ?? 0,
                cacheWrite: usage?.double("cacheWriteTokens") ?? 0,
                cacheRead: usage?.double("cacheReadTokens") ?? 0
            )
            let conversation = item.string("conversationId")
            return Event(
                id: "\(Int(millis)):\(model):\(conversation ?? "")",
                date: Date(timeIntervalSince1970: millis / 1000),
                model: model,
                tokens: tokens,
                cents: usage?.double("totalCents") ?? item.double("chargedCents") ?? 0,
                conversation: conversation
            )
        }
        return EventPage(events: events, total: Int(json.double("totalUsageEventsCount") ?? Double(events.count)))
    }

    /// Charts stay empty (not zero) until at least one event has been fetched,
    /// so a failed history call never reads as "no usage".
    static func detail(events: [Event], report: Report, days: Int, now: Date = Date(), calendar: Calendar = .current) -> UsageDetail {
        var hours: [Date: UsageAggregate] = [:]
        var daily: [Date: UsageAggregate] = [:]
        var week = UsageAggregate()
        var previousWeek = UsageAggregate()
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let previousStart = calendar.date(byAdding: .day, value: -days, to: weekStart) ?? weekStart
        for event in events {
            var usage = UsageAggregate()
            usage.tokens = event.tokens
            usage.messages = 1
            usage.cost = event.cents / 100
            if event.tokens.total > 0 {
                usage.models[event.model] = event.tokens.total
                usage.splits[UsageKey(model: event.model)] = event.tokens
            }
            if event.cents > 0 {
                usage.costs[event.model] = event.cents / 100 // Cursor's own accounting, not an estimate
            }
            if let conversation = event.conversation {
                usage.sessions.insert(conversation)
            }
            let day = calendar.startOfDay(for: event.date)
            if day >= weekStart {
                hours[UsageBucketing.floor(event.date, to: .hour, calendar: calendar), default: UsageAggregate()].merge(usage)
                daily[day, default: UsageAggregate()].merge(usage)
                week.merge(usage)
            } else if day >= previousStart {
                previousWeek.merge(usage)
            }
        }
        var meters: [UsageMeter] = []
        if let total = report.percentUsed {
            meters.append(UsageMeter(name: "Included usage", percent: total))
        }
        if let auto = report.autoPercentUsed {
            meters.append(UsageMeter(name: "Cursor models", percent: auto, note: report.autoMessage))
        }
        if let api = report.apiPercentUsed {
            meters.append(UsageMeter(name: "Other models", percent: api, note: report.apiMessage))
        }
        return UsageDetail(
            hours: events.isEmpty ? [] : UsageBucketing.series(hours, count: 24, component: .hour, endingAt: now, calendar: calendar),
            days: events.isEmpty ? [] : UsageBucketing.series(daily, count: days, component: .day, endingAt: now, calendar: calendar),
            week: week,
            meters: meters,
            previousWeek: events.isEmpty ? nil : previousWeek
        )
    }

    static func planLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw {
        case "pro_plus": return "Pro+"
        case "free": return "Hobby"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func snapshot(
        report: Report, credential: Credential, detail: UsageDetail,
        providerId: String, displayName: String, now: Date = Date()
    ) -> UsageSnapshot {
        UsageSnapshot(
            providerId: providerId,
            displayName: displayName,
            sessionPercent: nil,
            weeklyUsed: nil,
            weeklyLimit: nil,
            weeklyPercent: report.percentUsed,
            resetsAt: nil,
            credits: nil,
            spend: nil,
            spendCap: nil,
            spendPeriod: .billingCycle,
            plan: report.plan ?? credential.plan,
            status: .ok,
            lastUpdated: now,
            periodLabel: "billing cycle",
            weeklyResetsAt: report.cycleEnd,
            periodStartsAt: report.cycleStart,
            account: credential.email,
            detail: detail
        )
    }
}
