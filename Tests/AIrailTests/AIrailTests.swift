import XCTest
@testable import AIrail

final class AIrailTests: XCTestCase {

    // MARK: Snapshot math

    func testPercentClamp() {
        XCTAssertEqual(UsageSnapshot.clampPercent(-12), 0)
        XCTAssertEqual(UsageSnapshot.clampPercent(150), 100)
        XCTAssertEqual(UsageSnapshot.clampPercent(0), 0)
        XCTAssertEqual(UsageSnapshot.clampPercent(62), 62)
        XCTAssertEqual(UsageSnapshot.clampPercent(100), 100)
    }

    func testWeeklyPercentMath() {
        XCTAssertEqual(UsageSnapshot.percent(used: 1240, limit: 2000), 62)
        XCTAssertEqual(UsageSnapshot.percent(used: 0, limit: 2000), 0)
        XCTAssertEqual(UsageSnapshot.percent(used: 500, limit: 100), 100) // clamped
        XCTAssertNil(UsageSnapshot.percent(used: 10, limit: 0))
        XCTAssertNil(UsageSnapshot.percent(used: nil, limit: 100))
        XCTAssertNil(UsageSnapshot.percent(used: 10, limit: nil))
    }

    func testLastUpdatedString() {
        let now = Date()
        XCTAssertEqual(UsageFormatting.lastUpdatedString(now, now: now), "just now")
        XCTAssertEqual(UsageFormatting.lastUpdatedString(now.addingTimeInterval(-30), now: now), "30s ago")
        XCTAssertEqual(UsageFormatting.lastUpdatedString(now.addingTimeInterval(-300), now: now), "5m ago")
        XCTAssertEqual(UsageFormatting.lastUpdatedString(now.addingTimeInterval(-7200), now: now), "2h ago")
        XCTAssertEqual(UsageFormatting.lastUpdatedString(now.addingTimeInterval(-3 * 86400), now: now), "3d ago")
    }

    func testStaleMarkingKeepsNumbers() {
        let live = UsageSnapshot.empty(providerId: "x", displayName: "X", status: .ok)
        var withNumbers = live
        withNumbers.sessionPercent = 42
        let stale = withNumbers.marking(.stale)
        XCTAssertEqual(stale.status, .stale)
        XCTAssertEqual(stale.sessionPercent, 42)
    }

    // MARK: Provider registry

    @MainActor
    func testProviderRegistryIdsUnique() {
        let providers = ProviderManager.makeProviders()
        let ids = providers.map { $0.id }
        XCTAssertEqual(ids.count, 5, "ChatGPT is folded into the Codex account")
        XCTAssertEqual(Set(ids).count, ids.count, "provider ids must be unique")
        XCTAssertEqual(Set(ids), Set(AppSettings.allProviderIds))
    }

    @MainActor
    func testEveryProviderExplainsItsConnection() {
        for provider in ProviderManager.makeProviders() {
            XCTAssertFalse(provider.connection.summary.isEmpty, "\(provider.id) needs a picker caption")
            XCTAssertFalse(provider.connection.explainer.isEmpty, "\(provider.id) needs an explainer")
        }
    }

    // MARK: Demo data

    @MainActor
    func testDemoSnapshotsAreDemoWithSevenDayHistory() {
        for provider in ProviderManager.makeProviders() {
            let engine = MockUsageEngine(profile: provider.demoProfile)
            let snapshot = engine.snapshot(providerId: provider.id, displayName: provider.displayName)
            XCTAssertEqual(snapshot.providerId, provider.id)
            XCTAssertEqual(snapshot.weeklyHistory.count, 7)
            XCTAssertEqual(snapshot.status, .demo, "demo data is always badged demo")
            if let percent = snapshot.sessionPercent {
                XCTAssertTrue((0...100).contains(percent))
            }
            if let weekly = snapshot.weeklyPercent {
                XCTAssertTrue((0...100).contains(weekly))
            }
        }
    }

    @MainActor
    func testRandomWalkIsSlowAndBounded() {
        let walk = RandomWalk(start: 50, maxStep: 2)
        var previous = walk.value
        for _ in 0..<100 {
            let next = walk.step()
            XCTAssertLessThanOrEqual(abs(next - previous), 2.0001, "walk must drift, not jump")
            XCTAssertTrue((1...97).contains(next))
            previous = next
        }
    }

    // MARK: Accounts

    @MainActor
    func testAccountSettingsRoundTrip() {
        let suite = "AIrailTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.hasConnectedAccounts)

        settings.connect("claude")
        XCTAssertTrue(settings.isConnected("claude"))
        XCTAssertTrue(settings.isShownOnRail("claude"))
        settings.setShownOnRail(false, providerId: "claude")
        XCTAssertFalse(settings.isShownOnRail("claude"))
        XCTAssertFalse(settings.isShownOnRail("codex"), "unconnected accounts are never on the rail")

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.isConnected("claude"))
        XCTAssertFalse(reloaded.isShownOnRail("claude"))

        reloaded.disconnect("claude")
        XCTAssertFalse(reloaded.hasConnectedAccounts)
        XCTAssertTrue(reloaded.hiddenFromRailIds.isEmpty, "disconnecting clears the hidden flag too")
    }

    @MainActor
    func testRailMembershipFollowsAccounts() {
        let suite = "AIrailTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        let manager = ProviderManager(settings: settings)
        XCTAssertTrue(manager.isShowingDemo)
        XCTAssertEqual(manager.railProviderInfos.map(\.id), manager.demoProviderInfos.map(\.id))
        XCTAssertFalse(manager.railProviderInfos.isEmpty, "the demo rail is never empty")

        settings.connect("codex")
        XCTAssertFalse(manager.isShowingDemo)
        XCTAssertEqual(manager.railProviderInfos.map(\.id), ["codex"])
        XCTAssertEqual(manager.connectableProviderInfos.map(\.id), ["cursor", "claude", "gemini", "copilot"])

        settings.setShownOnRail(false, providerId: "codex")
        XCTAssertTrue(manager.railProviderInfos.isEmpty)
        XCTAssertEqual(manager.connectedProviderInfos.map(\.id), ["codex"], "hidden accounts stay connected")
    }

    // MARK: Date parsing

    func testISO8601WithSixFractionalDigits() {
        let date = DateParsing.iso8601("2026-09-02T09:30:00.479395+00:00")
        XCTAssertNotNil(date)
        XCTAssertEqual(date!.timeIntervalSince1970, 1_788_341_400.479, accuracy: 0.001)
        XCTAssertEqual(DateParsing.iso8601("2026-09-02T05:43:04.357Z")?.timeIntervalSince1970 ?? 0, 1_788_327_784.357, accuracy: 0.001)
        XCTAssertEqual(DateParsing.iso8601("2026-09-02T05:43:04Z")?.timeIntervalSince1970, 1_788_327_784)
        XCTAssertNil(DateParsing.iso8601("yesterday"))
        XCTAssertNil(DateParsing.iso8601(nil))
        XCTAssertEqual(DateParsing.day("2026-10-01")?.timeIntervalSince1970, 1_790_812_800)
    }

    func testBucketSeriesFillsGaps() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: today)!
        let eightDaysAgo = calendar.date(byAdding: .day, value: -8, to: today)!
        func usage(_ tokens: Double) -> UsageAggregate {
            var aggregate = UsageAggregate()
            aggregate.tokens = TokenSplit(input: tokens)
            return aggregate
        }
        let series = UsageBucketing.series(
            [today: usage(30), twoDaysAgo: usage(12), eightDaysAgo: usage(999)],
            count: 7, component: .day, endingAt: now, calendar: calendar
        )
        XCTAssertEqual(series.map { $0.usage.tokens.total }, [0, 0, 0, 0, 12, 0, 30])
        XCTAssertEqual(series.last?.start, today)

        let thisHour = UsageBucketing.floor(now, to: .hour, calendar: calendar)
        let hours = UsageBucketing.series([thisHour: usage(5)], count: 24, component: .hour, endingAt: now, calendar: calendar)
        XCTAssertEqual(hours.count, 24)
        XCTAssertEqual(hours.last?.usage.tokens.total, 5)
        XCTAssertEqual(hours.first?.start, calendar.date(byAdding: .hour, value: -23, to: thisHour))
    }

    func testAggregateMergeAndThinkingShare() {
        var a = UsageAggregate()
        a.tokens = TokenSplit(input: 10, output: 100, cacheWrite: 5, cacheRead: 50)
        a.thinking = 40
        a.messages = 2
        a.models = ["m1": 100]
        a.toolCalls = ["Bash": 3]
        a.sessions = ["s1"]
        var b = UsageAggregate()
        b.tokens = TokenSplit(output: 100)
        b.thinking = 10
        b.messages = 1
        b.models = ["m1": 50, "m2": 50]
        b.toolCalls = ["Bash": 1, "Edit": 2]
        b.sessions = ["s1", "s2"]
        a.merge(b)
        XCTAssertEqual(a.tokens.total, 10 + 200 + 5 + 50)
        XCTAssertEqual(a.thinkingShare!, 50.0 / 200.0, accuracy: 0.0001)
        XCTAssertEqual(a.messages, 3)
        XCTAssertEqual(a.models, ["m1": 150, "m2": 50])
        XCTAssertEqual(a.toolCalls, ["Bash": 4, "Edit": 2])
        XCTAssertEqual(a.sessions.count, 2)

        let detail = UsageDetail(week: a)
        XCTAssertEqual(detail.byModel.map(\.name), ["m1", "m2"])
        XCTAssertEqual(detail.topTools.map(\.name), ["Bash", "Edit"])
    }

    func testTokenAndModelFormatting() {
        XCTAssertEqual(UsageFormatting.compactTokens(950), "950")
        XCTAssertEqual(UsageFormatting.compactTokens(12_400), "12.4K")
        XCTAssertEqual(UsageFormatting.compactTokens(440_500_000), "441M")
        XCTAssertEqual(UsageFormatting.compactTokens(1_200_000_000), "1.2B")
        XCTAssertEqual(UsageFormatting.modelDisplayName("claude-fable-5"), "Fable 5")
        XCTAssertEqual(UsageFormatting.modelDisplayName("claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(UsageFormatting.modelDisplayName("gpt-5.5-mini"), "GPT-5.5 Mini")
        XCTAssertEqual(UsageFormatting.modelDisplayName("cursor-grok-4.6-high-fast"), "Grok 4.6 High Fast")
        XCTAssertEqual(UsageFormatting.modelDisplayName("gemini-3-pro"), "Gemini 3 Pro")
    }

    // MARK: Claude

    func testClaudeCredentialFromKeychainJSON() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"r","expiresAt":1788330749016,"scopes":["user:inference"],"subscriptionType":"max"}}"#
        let credential = try ClaudeUsage.credential(from: Data(json.utf8))
        XCTAssertEqual(credential.accessToken, "sk-ant-oat01-abc")
        XCTAssertEqual(credential.plan, "Max")
        XCTAssertEqual(credential.expiresAt!.timeIntervalSince1970, 1_788_330_749.016, accuracy: 0.001)

        XCTAssertThrowsError(try ClaudeUsage.credential(from: Data(#"{"other":{}}"#.utf8)))
    }

    func testClaudeUsageParse() throws {
        let json = #"""
        {"five_hour":{"utilization":2.0,"resets_at":"2026-09-02T09:30:00.479395+00:00","limit_dollars":null},
         "seven_day":{"utilization":31.5,"resets_at":"2026-09-08T02:00:00.479420+00:00"},
         "seven_day_opus":null,
         "extra_usage":{"is_enabled":false,"monthly_limit":5000,"used_credits":0.0,"decimal_places":2},
         "limits":[{"kind":"session","percent":2}]}
        """#
        let report = try ClaudeUsage.parse(Data(json.utf8))
        XCTAssertEqual(report.sessionPercent, 2)
        XCTAssertEqual(report.weeklyPercent, 31.5)
        XCTAssertEqual(report.sessionResetsAt!.timeIntervalSince1970, 1_788_341_400.479, accuracy: 0.001)
        XCTAssertNotNil(report.weeklyResetsAt)
        XCTAssertNil(report.extraSpend, "extra usage is off, so no spend line")

        let enabled = #"{"five_hour":{"utilization":50},"extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1234,"decimal_places":2}}"#
        let withSpend = try ClaudeUsage.parse(Data(enabled.utf8))
        XCTAssertEqual(withSpend.extraSpend, 12.34)
        XCTAssertEqual(withSpend.extraCap, 50)

        XCTAssertThrowsError(try ClaudeUsage.parse(Data(#"{"limits":[]}"#.utf8)))
    }

    func testClaudeTranscriptEventCarriesModelToolsAndProject() throws {
        let line = #"{"type":"assistant","timestamp":"2026-09-02T05:43:04.357Z","requestId":"req_1","cwd":"/Users/me/Developer/airail","sessionId":"sess-1","message":{"id":"msg_1","model":"claude-fable-5","usage":{"input_tokens":2,"cache_creation_input_tokens":6263,"cache_read_input_tokens":27499,"output_tokens":89,"output_tokens_details":{"thinking_tokens":17}},"content":[{"type":"tool_use","name":"Bash"},{"type":"text","text":"hi"}]}}"#
        var context = TranscriptContext()
        let event = ClaudeUsage.transcriptEvent(try Self.json(line), &context)
        XCTAssertEqual(event?.tokens.total, 2 + 6263 + 27499 + 89)
        XCTAssertEqual(event?.tokens.cacheRead, 27499)
        XCTAssertEqual(event?.thinking, 17)
        XCTAssertEqual(event?.model, "claude-fable-5")
        XCTAssertEqual(event?.project, "airail")
        XCTAssertEqual(event?.session, "sess-1")
        XCTAssertEqual(event?.toolCalls, ["Bash"])
        XCTAssertEqual(event?.dedupKey, "msg_1:req_1")

        let synthetic = #"{"type":"assistant","timestamp":"2026-09-02T05:43:04.357Z","message":{"id":"m","model":"<synthetic>","content":[]}}"#
        let syntheticEvent = ClaudeUsage.transcriptEvent(try Self.json(synthetic), &context)
        XCTAssertNil(syntheticEvent?.model)
        XCTAssertEqual(syntheticEvent?.countsAsMessage, false, "no usage block means no request to count")

        XCTAssertNil(ClaudeUsage.transcriptEvent(try Self.json(#"{"type":"user","timestamp":"2026-09-02T05:43:04.357Z"}"#), &context))
    }

    // MARK: Codex

    func testCodexCredentialReadsPlanAndEmailFromIdToken() throws {
        let idToken = Self.jwt([
            "email": "dev@example.com",
            "https://api.openai.com/auth": ["chatgpt_plan_type": "plus", "chatgpt_account_id": "acct-1"],
        ])
        let json = #"{"auth_mode":"chatgpt","tokens":{"id_token":"\#(idToken)","access_token":"at","refresh_token":"rt","account_id":"acct-1"},"last_refresh":"2026-08-27T06:29:46Z"}"#
        let credential = try CodexUsage.credential(from: Data(json.utf8))
        XCTAssertEqual(credential.accessToken, "at")
        XCTAssertEqual(credential.accountId, "acct-1")
        XCTAssertEqual(credential.email, "dev@example.com")
        XCTAssertEqual(credential.plan, "Plus")

        XCTAssertThrowsError(try CodexUsage.credential(from: Data(#"{"OPENAI_API_KEY":"sk"}"#.utf8)))
    }

    func testCodexUsageParseTellsWindowsApartByLength() throws {
        let json = #"""
        {"plan_type":"plus","email":"dev@example.com",
         "rate_limit":{"allowed":true,
           "primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_at":1788347019},
           "secondary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_at":1788933819}},
         "credits":{"has_credits":false,"balance":"0"}}
        """#
        let report = try CodexUsage.parse(Data(json.utf8))
        XCTAssertEqual(report.sessionPercent, 12)
        XCTAssertEqual(report.weeklyPercent, 40)
        XCTAssertEqual(report.sessionResetsAt?.timeIntervalSince1970, 1_788_347_019)
        XCTAssertEqual(report.weeklyResetsAt?.timeIntervalSince1970, 1_788_933_819)
        XCTAssertEqual(report.plan, "Plus")
        XCTAssertNil(report.credits)

        // Some responses only carry the weekly window under "primary".
        let weeklyOnly = #"{"rate_limit":{"primary_window":{"used_percent":7,"limit_window_seconds":604800,"reset_at":1}}}"#
        let single = try CodexUsage.parse(Data(weeklyOnly.utf8))
        XCTAssertNil(single.sessionPercent)
        XCTAssertEqual(single.weeklyPercent, 7)
    }

    func testCodexTranscriptEventsRememberSessionContext() throws {
        var context = TranscriptContext()
        let meta = #"{"timestamp":"2026-08-18T12:53:12.146Z","type":"session_meta","payload":{"id":"sess-9","cwd":"/Users/me/Developer/cfs"}}"#
        XCTAssertNil(CodexUsage.transcriptEvent(try Self.json(meta), &context))
        let turn = #"{"timestamp":"2026-08-18T12:53:13.000Z","type":"turn_context","payload":{"model":"gpt-5.5","effort":"high"}}"#
        XCTAssertNil(CodexUsage.transcriptEvent(try Self.json(turn), &context))

        let count = #"{"timestamp":"2026-08-18T12:59:31.567Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1682986},"last_token_usage":{"input_tokens":82284,"cached_input_tokens":80640,"cache_write_input_tokens":0,"output_tokens":565,"reasoning_output_tokens":127,"total_tokens":82849}},"rate_limits":{"primary":{"used_percent":12.0}}}}"#
        let event = CodexUsage.transcriptEvent(try Self.json(count), &context)
        XCTAssertEqual(event?.tokens.total, 82849)
        XCTAssertEqual(event?.tokens.cacheRead, 80640)
        XCTAssertEqual(event?.tokens.input, 82284 - 80640)
        XCTAssertEqual(event?.thinking, 127)
        XCTAssertEqual(event?.model, "gpt-5.5")
        XCTAssertEqual(event?.project, "cfs")
        XCTAssertEqual(event?.session, "sess-9")
        XCTAssertNil(event?.dedupKey)

        let call = #"{"timestamp":"2026-08-18T12:59:32.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{}"}}"#
        let toolEvent = CodexUsage.transcriptEvent(try Self.json(call), &context)
        XCTAssertEqual(toolEvent?.toolCalls, ["shell"])
        XCTAssertEqual(toolEvent?.countsAsMessage, false)
        XCTAssertEqual(toolEvent?.tokens.total, 0)

        let nullInfo = #"{"timestamp":"2026-08-18T12:59:33.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{}}}"#
        XCTAssertNil(CodexUsage.transcriptEvent(try Self.json(nullInfo), &context))
    }

    // MARK: Copilot

    func testCopilotParseFallsBackToChatWithoutPremiumQuota() throws {
        let json = #"""
        {"login":"octocat","copilot_plan":"individual","quota_reset_date":"2026-10-01",
         "quota_snapshots":{
           "chat":{"percent_remaining":75.0,"unlimited":false,"entitlement":200,"remaining":150},
           "completions":{"percent_remaining":100.0,"unlimited":false,"entitlement":2000,"remaining":2000},
           "premium_interactions":{"percent_remaining":0.0,"unlimited":false,"has_quota":false,"entitlement":0,"remaining":0}}}
        """#
        let report = try CopilotUsage.parse(Data(json.utf8))
        XCTAssertEqual(report.meter, "chat")
        XCTAssertEqual(report.used, 50)
        XCTAssertEqual(report.limit, 200)
        XCTAssertEqual(report.percentUsed, 25)
        XCTAssertEqual(report.plan, "Individual")
        XCTAssertEqual(report.login, "octocat")
        XCTAssertEqual(report.resetsAt?.timeIntervalSince1970, 1_790_812_800)
        XCTAssertEqual(report.meters.map(\.name), ["Chat", "Completions"], "a zero-entitlement meter is left out")
        XCTAssertEqual(report.meters.first?.used, 50)
        XCTAssertEqual(report.meters.last?.percent, 0)
    }

    func testCopilotParsePrefersPremiumRequests() throws {
        let json = #"""
        {"copilot_plan":"pro_plus","quota_reset_date":"2026-10-01",
         "quota_snapshots":{
           "chat":{"percent_remaining":100,"unlimited":true,"entitlement":0,"remaining":0},
           "premium_interactions":{"percent_remaining":38.5,"unlimited":false,"entitlement":1500,"remaining":577.5}}}
        """#
        let report = try CopilotUsage.parse(Data(json.utf8))
        XCTAssertEqual(report.meter, "premium")
        XCTAssertEqual(report.percentUsed, 61.5)
        XCTAssertEqual(report.used, 922.5)
        XCTAssertEqual(report.plan, "Pro+")
        let snapshot = CopilotUsage.snapshot(report: report, providerId: "copilot", displayName: "Copilot")
        XCTAssertEqual(snapshot.ringPercent, 61.5)
        XCTAssertEqual(snapshot.periodLabel, "monthly premium")
        XCTAssertEqual(snapshot.status, .ok)
    }

    func testCopilotExtensionToken() {
        let json = #"{"github.com:Iv1.abc":{"user":"octocat","oauth_token":"gho_xyz"}}"#
        XCTAssertEqual(CopilotUsage.extensionToken(from: Data(json.utf8)), "gho_xyz")
        XCTAssertNil(CopilotUsage.extensionToken(from: Data("{}".utf8)))
    }

    // MARK: Cursor

    func testCursorCredentialDerivesUserIdFromToken() throws {
        let token = Self.jwt(["sub": "auth0|user_01ABC", "exp": 1_792_738_780])
        let credential = try CursorUsage.credential(accessToken: token, email: "dev@example.com", membership: "pro_plus")
        XCTAssertEqual(credential.userId, "user_01ABC")
        XCTAssertEqual(credential.sessionCookie, "WorkosCursorSessionToken=user_01ABC%3A%3A\(token)")
        XCTAssertEqual(credential.plan, "Pro+")
        XCTAssertEqual(credential.expiresAt?.timeIntervalSince1970, 1_792_738_780)
        XCTAssertThrowsError(try CursorUsage.credential(accessToken: "not-a-jwt", email: nil, membership: nil))
    }

    func testCursorUsageSummaryParse() throws {
        let json = #"""
        {"billingCycleStart":"2026-08-25T06:00:19.000Z","billingCycleEnd":"2026-09-25T06:00:19.000Z",
         "membershipType":"pro_plus","isUnlimited":false,
         "individualUsage":{"plan":{"enabled":true,"used":1860,"limit":7000,"totalPercentUsed":1.4502923976608189},
                            "onDemand":{"enabled":false,"used":0}}}
        """#
        let report = try CursorUsage.parse(Data(json.utf8))
        XCTAssertEqual(report.percentUsed!, 1.45, accuracy: 0.01)
        XCTAssertEqual(report.plan, "Pro+")
        XCTAssertEqual(report.cycleEnd?.timeIntervalSince1970, 1_790_316_019)
        XCTAssertFalse(report.onDemandEnabled)
        XCTAssertThrowsError(try CursorUsage.parse(Data("{}".utf8)))
    }

    func testCursorEventsBuildChartsAndModelShares() throws {
        let now = Date()
        let calendar = Calendar.current
        let recent = Int(now.addingTimeInterval(-600).timeIntervalSince1970 * 1000)
        let yesterday = Int(now.addingTimeInterval(-86400).timeIntervalSince1970 * 1000)
        let json = #"""
        {"totalUsageEventsCount":3,"usageEventsDisplay":[
          {"timestamp":"\#(recent)","model":"grok-bot-default","kind":"USAGE_EVENT_KIND_INCLUDED_IN_PRO_PLUS","isTokenBasedCall":true,
           "tokenUsage":{"inputTokens":1875,"outputTokens":651,"cacheReadTokens":640,"totalCents":1.5952},"conversationId":"c1"},
          {"timestamp":"\#(recent - 1000)","model":"grok-bot-default","kind":"USAGE_EVENT_KIND_INCLUDED_IN_PRO_PLUS","isTokenBasedCall":false,"chargedCents":0,"conversationId":"c1"},
          {"timestamp":"\#(yesterday)","model":"claude-opus-5-low","tokenUsage":{"inputTokens":168,"outputTokens":21247,"cacheWriteTokens":218607,"cacheReadTokens":2041578,"totalCents":291.9},"conversationId":"c2"}]}
        """#
        let page = try CursorUsage.parseEvents(Data(json.utf8))
        XCTAssertEqual(page.total, 3)
        XCTAssertEqual(page.events.count, 3)
        XCTAssertEqual(page.events[1].tokens.total, 0, "calls without token usage still count as requests")

        let report = CursorUsage.Report(percentUsed: 1.45, autoPercentUsed: 0.7, apiPercentUsed: 12.2, autoMessage: "auto", apiMessage: "api", cycleEnd: nil, plan: "Pro+", onDemandEnabled: false)
        let detail = CursorUsage.detail(events: page.events, report: report, days: 7, now: now, calendar: calendar)
        XCTAssertEqual(detail.hours.count, 24)
        XCTAssertEqual(detail.days.count, 7)
        let lastTwoHours = detail.hours.suffix(2).reduce(0) { $0 + $1.usage.messages }
        XCTAssertEqual(lastTwoHours, 2, "both recent calls land in the last hour or the one before")
        XCTAssertEqual(detail.week.messages, 3)
        XCTAssertEqual(detail.week.sessions.count, 2)
        XCTAssertEqual(detail.byModel.first?.name, "claude-opus-5-low")
        XCTAssertEqual(detail.week.cost, (1.5952 + 291.9) / 100, accuracy: 0.0001)
        XCTAssertEqual(detail.meters.map(\.name), ["Included usage", "Auto mode", "API models"])
        XCTAssertEqual(detail.meters[2].note, "api")

        let empty = CursorUsage.detail(events: [], report: report, days: 7, now: now, calendar: calendar)
        XCTAssertTrue(empty.hours.isEmpty && empty.days.isEmpty, "no events fetched must not read as zero usage")
    }

    // MARK: Transcript scanner

    func testTranscriptScannerIsIncrementalAndDedups() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("airail-scanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        let yesterday = now.addingTimeInterval(-86400)
        func line(_ date: Date, id: String, tokens: Int) -> String {
            #"{"type":"assistant","timestamp":"\#(formatter.string(from: date))","requestId":"r","message":{"id":"\#(id)","usage":{"input_tokens":\#(tokens),"output_tokens":0}}}"#
        }
        let file = directory.appendingPathComponent("session.jsonl")
        let initial = [
            line(now, id: "a", tokens: 10),
            line(now, id: "a", tokens: 10), // streamed duplicate
            line(yesterday, id: "b", tokens: 5),
            #"{"type":"user","timestamp":"\#(formatter.string(from: now))"}"#,
        ].joined(separator: "\n") + "\n"
        try initial.write(to: file, atomically: true, encoding: .utf8)

        let scanner = TranscriptScanner(roots: [directory], requiredSubstrings: ["\"assistant\""], extractor: ClaudeUsage.transcriptEvent)
        let first = try await scanner.summary(days: 7, hours: 24, now: now)
        XCTAssertEqual(first.days.count, 7)
        XCTAssertEqual(first.hours.count, 24)
        XCTAssertEqual(first.days[6].usage.tokens.total, 10, "duplicate message counted once")
        XCTAssertEqual(first.days[6].usage.messages, 1)
        XCTAssertEqual(first.days[5].usage.tokens.total, 5)
        XCTAssertEqual(first.hours.last?.usage.tokens.total, 10)
        XCTAssertEqual(first.week.tokens.total, 15)

        // Append: only the new line should be read and added.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line(now, id: "c", tokens: 7) + "\n").utf8))
        try handle.close()
        let second = try await scanner.summary(days: 7, hours: 24, now: now)
        XCTAssertEqual(second.days[6].usage.tokens.total, 17)
        XCTAssertEqual(second.days[5].usage.tokens.total, 5)
        XCTAssertEqual(second.week.messages, 3)
    }

    // MARK: Brand icons

    func testBrandIconPathsParseWithinViewBox() {
        XCTAssertEqual(BrandIcons.all.count, 5)
        for data in BrandIcons.all {
            let path = SVGPathParser.parse(data)
            XCTAssertFalse(path.isEmpty, "brand icon must produce a non-empty path")
            let box = path.boundingRect
            XCTAssertTrue(box.minX >= -0.5 && box.minY >= -0.5, "path escapes the 24×24 viewBox")
            XCTAssertTrue(box.maxX <= 24.5 && box.maxY <= 24.5, "path escapes the 24×24 viewBox")
            XCTAssertTrue(box.width > 10 && box.height > 10, "icon suspiciously small — parser likely bailed early")
        }
    }

    // MARK: Helpers

    private static func json(_ text: String) throws -> JSONObject {
        JSONObject(try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
    }

    /// An unsigned JWT with the given payload — the readers only decode, never verify.
    private static func jwt(_ claims: [String: Any]) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: claims)
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(encoded).sig"
    }
}
