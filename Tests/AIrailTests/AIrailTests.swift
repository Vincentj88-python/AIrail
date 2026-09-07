import UserNotifications
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

    /// A stale reading keeps its numbers only while the window they were
    /// read from still exists: past its reset the session figures go, past
    /// the weekly reset the rest (and the meters) go, and the snapshot
    /// remembers which window ended so the card can say so.
    func testStaleNumbersExpireAtTheirReset() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var snapshot = UsageSnapshot.empty(providerId: "claude", displayName: "Claude", status: .stale)
        snapshot.sessionPercent = 88
        snapshot.resetsAt = now.addingTimeInterval(-60)
        snapshot.weeklyPercent = 40
        snapshot.weeklyResetsAt = now.addingTimeInterval(6 * 24 * 3600)
        snapshot.detail.meters = [UsageMeter(name: "Opus", percent: 30)]

        let afterSession = snapshot.expiringWindows(now: now)
        XCTAssertNil(afterSession.sessionPercent)
        XCTAssertNil(afterSession.resetsAt)
        XCTAssertEqual(afterSession.ringPercent, 40, "the weekly window is still real, so the ring falls back to it")
        XCTAssertEqual(afterSession.expiredResetAt, now.addingTimeInterval(-60))
        XCTAssertEqual(afterSession.expiredWindowLabel, "session")
        XCTAssertEqual(afterSession.detail.meters.count, 1, "the meters belong to the weekly window")

        let afterWeek = snapshot.expiringWindows(now: now.addingTimeInterval(7 * 24 * 3600))
        XCTAssertNil(afterWeek.ringPercent)
        XCTAssertNil(afterWeek.weeklyResetsAt)
        XCTAssertTrue(afterWeek.detail.meters.isEmpty)
        XCTAssertEqual(afterWeek.expiredWindowLabel, "weekly", "the later reset is the one named")

        XCTAssertEqual(snapshot.expiringWindows(now: now.addingTimeInterval(-120)), snapshot, "nothing expires before its reset")

        var monthly = UsageSnapshot.empty(providerId: "copilot", displayName: "Copilot", status: .stale)
        monthly.weeklyPercent = 61
        monthly.weeklyUsed = 923
        monthly.weeklyLimit = 1500
        monthly.periodLabel = "monthly"
        monthly.resetsAt = now.addingTimeInterval(-1)
        let expiredMonthly = monthly.expiringWindows(now: now)
        XCTAssertNil(expiredMonthly.weeklyUsed)
        XCTAssertNil(expiredMonthly.resetsAt, "a provider with only a long window keeps its reset in resetsAt")
        XCTAssertEqual(expiredMonthly.expiredWindowLabel, "monthly")
    }

    // MARK: Provider registry

    @MainActor
    func testProviderRegistryIdsUnique() {
        let providers = ProviderManager.makeProviders()
        let ids = providers.map { $0.id }
        XCTAssertEqual(ids.count, 9, "five tools (ChatGPT is folded into Codex) plus four keyed platforms")
        XCTAssertEqual(Set(ids).count, ids.count, "provider ids must be unique")
        XCTAssertEqual(Set(ids), Set(AppSettings.allProviderIds))
        XCTAssertEqual(providers.filter { $0.kind == .tool }.map(\.id), AppSettings.toolProviderIds)
        XCTAssertEqual(providers.filter { $0.kind == .apiKey }.map(\.id), AppSettings.platformProviderIds)
    }

    @MainActor
    func testEveryProviderExplainsItsConnection() {
        for provider in ProviderManager.makeProviders() {
            XCTAssertFalse(provider.connection.summary.isEmpty, "\(provider.id) needs a picker caption")
            XCTAssertFalse(provider.connection.explainer.isEmpty, "\(provider.id) needs an explainer")
            let footprint = Footprint.items(for: provider.id)
            if provider.connection.isSupported {
                XCTAssertFalse(footprint.isEmpty, "\(provider.id) must say what it touches, for the Privacy pane")
                XCTAssertTrue(footprint.contains { $0.host != nil }, "\(provider.id) must name the host it asks")
            }
            for host in footprint.compactMap(\.host) {
                XCTAssertTrue(HTTPClient.allowedHosts.contains(host), "\(provider.id) names \(host), which the allowlist refuses")
            }
        }
        XCTAssertEqual(Set(Footprint.hosts.keys), HTTPClient.allowedHosts, "the Privacy pane describes exactly the allowlist")
    }

    /// The ledger is the allowlist with dates on it: one row per host, updated in place.
    @MainActor
    func testNetworkLedgerKeepsOneRowPerHost() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = NetworkLedger(since: now)
        ledger.record(host: "api.anthropic.com", method: "GET", path: "/api/oauth/usage", status: 200, at: now)
        ledger.record(host: "cursor.com", method: "POST", path: "/api/dashboard/get-filtered-usage-events", status: 200, at: now.addingTimeInterval(1))
        ledger.record(host: "api.anthropic.com", method: "GET", path: "/api/oauth/usage", status: 429, at: now.addingTimeInterval(2))
        XCTAssertEqual(ledger.entries.map(\.host), ["api.anthropic.com", "cursor.com"], "newest contact first")
        XCTAssertEqual(ledger.entries.first?.count, 2)
        XCTAssertEqual(ledger.entries.first?.status, 429)
        XCTAssertEqual(ledger.entries.first?.lastContact, now.addingTimeInterval(2))
        XCTAssertNotNil(SigningInfo.current(), "the test bundle's signature reads without a prompt")
    }

    // MARK: Demo data

    @MainActor
    func testDemoSnapshotsAreDemoWithSevenDayHistory() {
        for provider in ProviderManager.makeProviders() {
            let engine = MockUsageEngine(profile: provider.demoProfile)
            let snapshot = engine.snapshot(providerId: provider.id, displayName: provider.displayName)
            XCTAssertEqual(snapshot.providerId, provider.id)
            XCTAssertEqual(snapshot.detail.days.count, 7)
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
    func testRailPositionMigratesFromSide() {
        let suite = "AIrailTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AppSettings(defaults: defaults).position, .left, "fresh install hugs the left edge")

        defaults.set("right", forKey: "railSide")
        let migrated = AppSettings(defaults: defaults)
        XCTAssertEqual(migrated.position, .right, "v0.1's side setting carries over")
        XCTAssertEqual(migrated.railSide, .right)

        migrated.position = .top
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.position, .top)
        XCTAssertEqual(reloaded.railSide, .left, "Top's edge fallback is the left")

        // v0.2 stored Notch and Island as two positions; both come back as Top.
        for legacy in ["notch", "island"] {
            defaults.set(legacy, forKey: "railPosition")
            XCTAssertEqual(AppSettings(defaults: defaults).position, .top, "v0.2's \(legacy) is Top now")
        }
        defaults.set("sideways", forKey: "railPosition")
        XCTAssertEqual(AppSettings(defaults: defaults).position, .left, "an unknown value falls back to the left edge")
    }

    func testVirtualNotchSitsInTheMenuBarCentre() {
        let ultrawide = NSRect(x: 0, y: 0, width: 3440, height: 1440)
        let pill = NotchGeometry.virtualRect(in: ultrawide, menuBarHeight: 30)
        XCTAssertEqual(pill.midX, 1720)
        XCTAssertEqual(pill.maxY, 1440, "flush with the top of the display")
        XCTAssertEqual(pill.height, 30, "as tall as the menu bar")
        XCTAssertEqual(pill.width, NotchGeometry.virtualWidth)

        let noMenuBar = NotchGeometry.virtualRect(in: NSRect(x: -1920, y: 360, width: 1920, height: 1080), menuBarHeight: 0)
        XCTAssertEqual(noMenuBar.height, 0, "a display without a menu bar has no band: the hairline sits at the very top")
        XCTAssertEqual(noMenuBar.midX, -960)

        XCTAssertTrue(AppSettings.RailPosition.top.isTop)
        XCTAssertFalse(AppSettings.RailPosition.left.isTop)
        XCTAssertEqual(AppSettings.RailPosition.allCases.map(\.label), ["Left", "Right", "Top"])
    }

    func testAutomaticRailDisplayIsTheOuterEdge() {
        // Vincent's desk: Dell | ultrawide (main) | MacBook, left to right.
        let dell = NSRect(x: -1920, y: 360, width: 1920, height: 1080)
        let ultrawide = NSRect(x: 0, y: 0, width: 3440, height: 1440)
        let macbook = NSRect(x: 3440, y: -52, width: 1800, height: 1169)
        let frames = [ultrawide, macbook, dell]
        XCTAssertEqual(ScreenSelection.outerIndex(side: .left, frames: frames), 2, "left means the Dell's left edge, not the seam at x=0")
        XCTAssertEqual(ScreenSelection.outerIndex(side: .right, frames: frames), 1, "right means the MacBook's right edge")

        // Stacked displays share an x range: the taller one gets the rail.
        let stacked = [NSRect(x: 0, y: 0, width: 1800, height: 1169), NSRect(x: 0, y: 1169, width: 1800, height: 1440)]
        XCTAssertEqual(ScreenSelection.outerIndex(side: .left, frames: stacked), 1)
        XCTAssertNil(ScreenSelection.outerIndex(side: .left, frames: []))

        // Seams: the ultrawide's edges both continue onto another display; the Dell's left and the MacBook's right don't.
        XCTAssertEqual(ScreenSelection.neighbourIndex(beyond: ultrawide, side: .left, frames: [macbook, dell]), 1)
        XCTAssertEqual(ScreenSelection.neighbourIndex(beyond: ultrawide, side: .right, frames: [macbook, dell]), 0)
        XCTAssertNil(ScreenSelection.neighbourIndex(beyond: dell, side: .left, frames: [ultrawide, macbook]))
        XCTAssertNil(ScreenSelection.neighbourIndex(beyond: macbook, side: .right, frames: [ultrawide, dell]))
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

        XCTAssertTrue(manager.demoProviderInfos.allSatisfy { $0.kind == .tool }, "keyed platforms never show demo data")

        settings.connect("codex")
        XCTAssertFalse(manager.isShowingDemo)
        XCTAssertEqual(manager.railProviderInfos.map(\.id), ["codex"])
        XCTAssertEqual(manager.connectableProviderInfos.map(\.id), ["cursor", "claude", "gemini", "copilot"])
        XCTAssertEqual(manager.connectablePlatformInfos.map(\.id), AppSettings.platformProviderIds)

        settings.setShownOnRail(false, providerId: "codex")
        XCTAssertTrue(manager.railProviderInfos.isEmpty)
        XCTAssertEqual(manager.connectedProviderInfos.map(\.id), ["codex"], "hidden accounts stay connected")

        settings.connect("openrouter")
        XCTAssertEqual(manager.railProviderInfos.map(\.id), ["openrouter"], "keyed accounts ride the rail like any other")
        XCTAssertEqual(manager.connectedProviderInfos.map(\.id), ["codex", "openrouter"])
        XCTAssertEqual(manager.connectablePlatformInfos.map(\.id), ["deepseek", "anthropic-api", "openai-api"])
    }

    func testTemporaryKeychainErrorIsTransient() {
        let err = ConnectionError.temporarilyUnavailable(tool: "Claude Code")
        XCTAssertTrue(err.isTransient, "a Keychain hiccup keeps the last real numbers and retries")
        XCTAssertEqual(err.shortDescription, "Reading sign-in — retrying")
        XCTAssertTrue(err.errorDescription?.contains("Keychain") == true)
    }

    func testRateLimitErrorIsTransientAndReadsRetryAfter() {
        let soon = Date().addingTimeInterval(300)
        let err = ConnectionError.rateLimited(tool: "Claude Code", retryAfter: soon)
        XCTAssertTrue(err.isTransient, "a 429 keeps the last real numbers, marked stale")
        XCTAssertEqual(err.shortDescription, "Checked too often — waiting")
        XCTAssertTrue(err.errorDescription?.contains("limiting how often") == true, err.errorDescription ?? "")
        XCTAssertEqual(UsageFormatting.clockString(Date().addingTimeInterval(5)), "shortly")
        XCTAssertTrue(UsageFormatting.clockString(soon).hasPrefix("at "))
        XCTAssertTrue(ConnectionError.offline.isTransient, "offline keeps the last numbers")
        let drift = ConnectionError.shapeChanged(tool: "Cursor", detail: "keys: a, b")
        XCTAssertTrue(drift.isTransient, "a moved endpoint keeps the last numbers as stale")
        XCTAssertTrue(drift.isShapeChange)
        XCTAssertFalse(ConnectionError.offline.isShapeChange)
        XCTAssertEqual(drift.errorDescription, "Cursor sent usage data in a form AIrail can't read yet. Check for an update.")
        XCTAssertEqual(drift.shortDescription, "Unexpected data — check for update")
        XCTAssertTrue(ConnectionError.offline.isNetworkOutage)
        XCTAssertTrue(ConnectionError.network("x").isNetworkOutage)
        XCTAssertFalse(ConnectionError.expired(tool: "T").isNetworkOutage)
        XCTAssertEqual(ConnectionError.offline.symbolName, "wifi.slash")
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

    /// Claude Code names its Keychain item after CLAUDE_CONFIG_DIR: the plain
    /// name when unset, "-<sha8>" of the NFC path when set. AIrail can't see
    /// a shell export, so it tries the legacy name, the default folder's hash
    /// and any value in its own environment, in that order.
    func testClaudeKeychainServiceNamesFollowTheConfigDir() {
        XCTAssertEqual(
            ClaudeUsage.keychainServices(home: "/Users/vincentjacobs", configDir: nil),
            ["Claude Code-credentials", "Claude Code-credentials-88404443"]
        )
        XCTAssertEqual(
            ClaudeUsage.keychainServices(home: "/Users/vincentjacobs", configDir: "/tmp/claude-work"),
            ["Claude Code-credentials", "Claude Code-credentials-88404443", "Claude Code-credentials-bfc1769a"]
        )
        XCTAssertEqual(
            ClaudeUsage.keychainServices(home: "/Users/vincentjacobs", configDir: "/Users/vincentjacobs/.claude").count, 2,
            "exporting the default folder names the same item"
        )
        let decomposed = "/Users/Ame\u{0301}lie/.claude"
        let composed = "/Users/Am\u{00E9}lie/.claude"
        XCTAssertEqual(
            ClaudeUsage.keychainServices(home: "/x", configDir: decomposed).last,
            ClaudeUsage.keychainServices(home: "/x", configDir: composed).last,
            "hashed over the NFC form, as Claude Code does"
        )
        // Names that don't exist are answered without a prompt and without a read.
        let absent = ["AIrail-no-such-item-\(UUID().uuidString)"]
        XCTAssertTrue(KeychainReader.existingServices(absent).isEmpty)
        XCTAssertThrowsError(try KeychainReader.genericPassword(services: absent, tool: "Test")) { error in
            XCTAssertEqual((error as? ConnectionError)?.shortDescription, "Test not signed in")
        }
    }

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

        let credential = ClaudeUsage.Credential(accessToken: "t", expiresAt: nil, plan: "Max")
        let snapshot = ClaudeUsage.snapshot(
            report: withSpend, credential: credential, transcripts: nil, providerId: "claude", displayName: "Claude"
        )
        XCTAssertEqual(snapshot.spend, 12.34)
        XCTAssertEqual(snapshot.spendCap, 50)
        XCTAssertEqual(snapshot.spendPeriod, .billingCycle, "extra usage runs with the billing month, not the calendar one")

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
        XCTAssertEqual(snapshot.unitLabel, "requests")
        XCTAssertEqual(snapshot.status, .ok)
    }

    /// The 2026 shape: monthly plans bill AI credits (1 credit = $0.01) and
    /// flag it with `token_based_billing`; chat and completions carry the
    /// `-1` unlimited sentinel. Fixture from GitHub's copilot-sdk typings —
    /// this Mac's account is Free, so the paid shape is not verifiable here.
    func testCopilotParseReadsAICredits() throws {
        let json = #"""
        {"login":"octocat","copilot_plan":"pro","token_based_billing":true,"quota_reset_date":"2026-10-01",
         "quota_snapshots":{
           "chat":{"percent_remaining":100,"unlimited":false,"entitlement":-1,"remaining":-1},
           "completions":{"percent_remaining":100,"unlimited":true,"entitlement":-1,"remaining":-1},
           "premium_interactions":{"percent_remaining":38.47,"unlimited":false,"entitlement":1500,"remaining":577,
             "credits_used":923,"overage_count":0,"overage_entitlement":500,"token_based_billing":true}}}
        """#
        let report = try CopilotUsage.parse(Data(json.utf8), locale: Locale(identifier: "en_US"))
        XCTAssertEqual(report.meter, "credits")
        XCTAssertEqual(report.used, 923)
        XCTAssertEqual(report.limit, 1500)
        XCTAssertEqual(report.plan, "Pro")
        XCTAssertEqual(report.meters.map(\.name), ["AI credits", "Chat", "Completions"])
        XCTAssertEqual(report.meters[0].note, "1 credit = $0.01 · ≈ $9.23 of $15.00")
        XCTAssertEqual(report.meters[1].note, "Unlimited", "-1 is GitHub's unlimited sentinel, even without the flag")
        let snapshot = CopilotUsage.snapshot(report: report, providerId: "copilot", displayName: "Copilot")
        XCTAssertEqual(snapshot.periodLabel, "monthly")
        XCTAssertEqual(snapshot.unitLabel, "AI credits")
        XCTAssertEqual(snapshot.ringPercent.map { ($0 * 100).rounded() / 100 }, 61.53, "the ring stays GitHub's own percentage")
        XCTAssertEqual(
            CopilotUsage.creditsNote(used: 1620, entitlement: 1500, overage: 120, locale: Locale(identifier: "en_US")),
            "1 credit = $0.01 · ≈ $16.20 of $15.00 · 120 over plan"
        )
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
        XCTAssertThrowsError(try CursorUsage.parse(Data("{}".utf8)))
    }

    func testCursorSnapshotBillsByCycle() throws {
        let report = CursorUsage.Report(percentUsed: 1.45, autoPercentUsed: nil, apiPercentUsed: nil, autoMessage: nil, apiMessage: nil, cycleEnd: Date(timeIntervalSince1970: 1_790_316_019), plan: "Pro+")
        let credential = CursorUsage.Credential(userId: "user_1", accessToken: "t", expiresAt: nil, email: "v@example.com", plan: nil)
        let snapshot = CursorUsage.snapshot(report: report, credential: credential, detail: UsageDetail(), providerId: "cursor", displayName: "Cursor")
        XCTAssertEqual(snapshot.spendPeriod, .billingCycle, "whatever fills spend later is measured over the billing cycle")
        XCTAssertEqual(snapshot.periodLabel, "billing cycle")
        XCTAssertEqual(snapshot.weeklyResetsAt, report.cycleEnd)
        XCTAssertNil(snapshot.spend, "the summary endpoint reports no spend today")
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

        let report = CursorUsage.Report(percentUsed: 1.45, autoPercentUsed: 0.7, apiPercentUsed: 12.2, autoMessage: "auto", apiMessage: "api", cycleEnd: nil, plan: "Pro+")
        let detail = CursorUsage.detail(events: page.events, report: report, days: 7, now: now, calendar: calendar)
        XCTAssertEqual(detail.hours.count, 24)
        XCTAssertEqual(detail.days.count, 7)
        let lastTwoHours = detail.hours.suffix(2).reduce(0) { $0 + $1.usage.messages }
        XCTAssertEqual(lastTwoHours, 2, "both recent calls land in the last hour or the one before")
        XCTAssertEqual(detail.week.messages, 3)
        XCTAssertEqual(detail.week.sessions.count, 2)
        XCTAssertEqual(detail.byModel.first?.name, "claude-opus-5-low")
        XCTAssertEqual(detail.week.cost, (1.5952 + 291.9) / 100, accuracy: 0.0001)
        XCTAssertEqual(detail.meters.map(\.name), ["Included usage", "Cursor models", "Other models"], "the pools carry their dashboard names")
        XCTAssertEqual(detail.meters[2].note, "api")

        let empty = CursorUsage.detail(events: [], report: report, days: 7, now: now, calendar: calendar)
        XCTAssertTrue(empty.hours.isEmpty && empty.days.isEmpty, "no events fetched must not read as zero usage")
    }

    // MARK: Keyed platforms

    func testOpenRouterSnapshot() throws {
        let key = #"{"data":{"label":"laptop","usage":12.5,"limit":50,"limit_remaining":37.5,"is_free_tier":false,"rate_limit":{"requests":200,"interval":"10s"}}}"#
        let credits = #"{"data":{"total_credits":100,"total_usage":40.25}}"#
        let snapshot = try OpenRouterUsage.snapshot(keyData: Data(key.utf8), creditsData: Data(credits.utf8), providerId: "openrouter", displayName: "OpenRouter")
        XCTAssertEqual(snapshot.weeklyPercent, 25)
        XCTAssertEqual(snapshot.periodLabel, "key limit")
        XCTAssertEqual(snapshot.spend, 12.5)
        XCTAssertEqual(snapshot.spendCap, 50)
        XCTAssertEqual(snapshot.spendPeriod, .keyLimit, "a limit that never resets is the key's own budget")
        XCTAssertEqual(snapshot.credits, 59.75)
        XCTAssertEqual(snapshot.creditsCurrency, "USD")
        XCTAssertEqual(snapshot.account, "laptop")
        XCTAssertNil(snapshot.plan)
        XCTAssertEqual(snapshot.status, .ok)

        // A weekly-resetting limit: `usage` is all time and already past the
        // limit, `limit_remaining` is what OpenRouter counts this week.
        let weeklyKey = #"{"data":{"label":"w","usage":120,"usage_monthly":4.2,"limit":50,"limit_remaining":40,"limit_reset":"weekly"}}"#
        let weekly = try OpenRouterUsage.snapshot(keyData: Data(weeklyKey.utf8), creditsData: nil, providerId: "openrouter", displayName: "OpenRouter")
        XCTAssertEqual(weekly.weeklyPercent, 20, "the ring is what's used of the limit, not lifetime usage")
        XCTAssertEqual(weekly.spend, 10)
        XCTAssertEqual(weekly.spendCap, 50)
        XCTAssertEqual(weekly.spendPeriod, .keyLimit, "a monthly figure must not sit under a weekly cap")
        XCTAssertNil(weekly.credits)

        let monthlyKey = #"{"data":{"label":"m","usage":120,"usage_monthly":4.2,"limit":50,"limit_remaining":45.8,"limit_reset":"monthly"}}"#
        let monthly = try OpenRouterUsage.snapshot(keyData: Data(monthlyKey.utf8), creditsData: nil, providerId: "openrouter", displayName: "OpenRouter")
        XCTAssertEqual(try XCTUnwrap(monthly.weeklyPercent), 8.4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(monthly.spend), 4.2, accuracy: 0.001, "ring and footer count the same thing, whatever clock the limit resets on")
        XCTAssertEqual(monthly.spendCap, 50)
        XCTAssertEqual(monthly.spendPeriod, .keyLimit)

        let openKey = #"{"data":{"label":"o","usage":120,"usage_monthly":4.2,"limit":null,"limit_remaining":null,"limit_reset":null,"is_free_tier":false}}"#
        let open = try OpenRouterUsage.snapshot(keyData: Data(openKey.utf8), creditsData: Data(credits.utf8), providerId: "openrouter", displayName: "OpenRouter")
        XCTAssertEqual(open.weeklyPercent!, 40.25, accuracy: 0.001, "without a key limit the ring is credits used")
        XCTAssertEqual(open.periodLabel, "credits")
        XCTAssertEqual(open.spend, 4.2, "an open key shows this UTC month, not everything ever spent")
        XCTAssertNil(open.spendCap)
        XCTAssertEqual(open.spendPeriod, .month)

        let unlimitedKey = #"{"data":{"label":"k","usage":3,"limit":null,"is_free_tier":true}}"#
        let noLimit = try OpenRouterUsage.snapshot(keyData: Data(unlimitedKey.utf8), creditsData: Data(credits.utf8), providerId: "openrouter", displayName: "OpenRouter")
        XCTAssertEqual(noLimit.weeklyPercent!, 40.25, accuracy: 0.001)
        XCTAssertEqual(noLimit.periodLabel, "credits")
        XCTAssertEqual(noLimit.plan, "Free tier")
        XCTAssertEqual(noLimit.spend, 3, "no monthly figure: the lifetime total, labelled as such")
        XCTAssertEqual(noLimit.spendPeriod, .lifetime)
        XCTAssertNil(noLimit.spendCap)

        // Neither figure in the answer: the footer stays empty rather than
        // printing a $0.00 nobody reported.
        let bareKey = #"{"data":{"label":"b","limit":null,"is_free_tier":false}}"#
        let bare = try OpenRouterUsage.snapshot(keyData: Data(bareKey.utf8), creditsData: Data(credits.utf8), providerId: "openrouter", displayName: "OpenRouter")
        XCTAssertNil(bare.spend, "no usage figure at all is not $0.00")
        XCTAssertEqual(try XCTUnwrap(bare.weeklyPercent), 40.25, accuracy: 0.001, "the credits ring stands on its own")
        XCTAssertThrowsError(try OpenRouterUsage.snapshot(keyData: Data("{}".utf8), creditsData: nil, providerId: "openrouter", displayName: "OpenRouter"))
    }

    func testDeepSeekSnapshot() throws {
        let json = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"88.00","granted_balance":"0.00","topped_up_balance":"88.00"},{"currency":"USD","total_balance":"12.34","granted_balance":"0.00","topped_up_balance":"12.34"}]}"#
        let snapshot = try DeepSeekUsage.snapshot(data: Data(json.utf8), providerId: "deepseek", displayName: "DeepSeek")
        XCTAssertEqual(snapshot.credits, 12.34, "USD balance preferred when present")
        XCTAssertEqual(snapshot.creditsCurrency, "USD")
        XCTAssertNil(snapshot.ringPercent, "a balance has no limit to ring")
        XCTAssertNil(snapshot.spend)
        XCTAssertThrowsError(try DeepSeekUsage.snapshot(data: Data(#"{"is_available":false,"balance_infos":[]}"#.utf8), providerId: "deepseek", displayName: "DeepSeek"))
    }

    func testMoneyFollowsTheLocaleAndSpendCaptionsNameTheWindow() throws {
        let us = Locale(identifier: "en_US")
        let gb = Locale(identifier: "en_GB")
        XCTAssertEqual(UsageFormatting.dollars(12.5, locale: us), "$12.50")
        XCTAssertEqual(UsageFormatting.dollars(1234.5, locale: us), "$1,234.50")
        XCTAssertEqual(UsageFormatting.dollars(12.5, locale: gb), "US$12.50", "the code is fixed, the symbol follows the locale")
        XCTAssertEqual(UsageFormatting.credits(12.34, currency: "USD", locale: us), "$12.34")
        XCTAssertEqual(UsageFormatting.credits(88, currency: "CNY", locale: us), "CN¥88.00")
        XCTAssertEqual(UsageFormatting.credits(88, currency: "cny", locale: us), "CN¥88.00", "lowercase codes are still codes")
        XCTAssertEqual(UsageFormatting.credits(8760, currency: nil, locale: us), "8,760")

        let now = Date()
        XCTAssertEqual(UsageFormatting.spendCaption(.month, now: now), "SPEND (\(UsageFormatting.currentMonthAbbreviation(now)))")
        XCTAssertEqual(UsageFormatting.spendCaption(.billingCycle), "SPEND (THIS CYCLE)")
        XCTAssertEqual(UsageFormatting.spendCaption(.lifetime), "SPEND (ALL TIME)")
        XCTAssertEqual(UsageFormatting.spendCaption(.keyLimit), "SPEND (KEY LIMIT)")
        XCTAssertEqual(UsageFormatting.spendLabel(.lifetime), "Spend, all time")
        XCTAssertEqual(UsageSnapshot.empty(providerId: "x", displayName: "X", status: .ok).spendPeriod, .month, "month-to-date is the default every org cost report uses")

        // Every `.month` producer measures the UTC month, so the caption names
        // that one: 23:30 UTC on 31 August is still August whatever zone the
        // Mac is in, and 00:30 UTC on 1 September is September.
        let iso = ISO8601DateFormatter()
        let lateAugust = try XCTUnwrap(iso.date(from: "2026-08-31T23:30:00Z"))
        let earlySeptember = try XCTUnwrap(iso.date(from: "2026-09-01T00:30:00Z"))
        let august = try XCTUnwrap(iso.date(from: "2026-08-15T12:00:00Z"))
        let september = try XCTUnwrap(iso.date(from: "2026-09-15T12:00:00Z"))
        XCTAssertEqual(UsageFormatting.spendCaption(.month, now: lateAugust), UsageFormatting.spendCaption(.month, now: august))
        XCTAssertEqual(UsageFormatting.spendCaption(.month, now: earlySeptember), UsageFormatting.spendCaption(.month, now: september))
        XCTAssertNotEqual(UsageFormatting.spendCaption(.month, now: lateAugust), UsageFormatting.spendCaption(.month, now: earlySeptember))
    }

    func testAnthropicAPISnapshot() throws {
        let now = Date()
        let calendar = Calendar.current
        let todayUTC = AnthropicAPIUsage.utcDayWindow(days: 1, now: now).0
        let iso = AnthropicAPIUsage.iso(todayUTC)
        let usage = #"""
        {"data":[{"starting_at":"\#(iso)","ending_at":"\#(iso)","results":[
          {"model":"claude-opus-5","uncached_input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":8000,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":300}},
          {"model":"claude-sonnet-5","uncached_input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0}}]}],"has_more":false}
        """#
        let cost = #"{"data":[{"starting_at":"\#(iso)","results":[{"currency":"USD","amount":"1234.5","cost_type":"tokens"},{"currency":"USD","amount":"100","cost_type":"web_search"}]}]}"#
        let snapshot = try AnthropicAPIUsage.snapshot(usageData: Data(usage.utf8), costData: Data(cost.utf8), providerId: "anthropic-api", displayName: "Anthropic API", now: now)
        XCTAssertEqual(snapshot.spend!, 13.345, accuracy: 0.0001, "cost amounts are minor units")
        XCTAssertEqual(snapshot.detail.days.count, 7)
        let today = try XCTUnwrap(snapshot.detail.days.last)
        XCTAssertEqual(today.usage.tokens.total, 1000 + 500 + 8000 + 500 + 150)
        XCTAssertEqual(snapshot.detail.byModel.first?.name, "claude-opus-5")
        XCTAssertEqual(snapshot.detail.week.tokens.cacheWrite, 500)
        XCTAssertEqual(calendar.startOfDay(for: today.start), calendar.startOfDay(for: now))

        let url = AnthropicAPIUsage.usageURL(now: now).absoluteString
        XCTAssertTrue(url.contains("bucket_width=1d") && url.contains("group_by%5B%5D=model"), url)
    }

    func testOpenAIAPISnapshot() throws {
        let now = Date()
        let todayUTC = Int(AnthropicAPIUsage.utcDayWindow(days: 1, now: now).0.timeIntervalSince1970)
        let usage = #"""
        {"object":"page","data":[{"object":"bucket","start_time":\#(todayUTC),"end_time":\#(todayUTC + 86400),"results":[
          {"object":"organization.usage.completions.result","input_tokens":5000,"output_tokens":700,"input_cached_tokens":3000,"num_model_requests":12,"model":"gpt-5.5"}]}],"has_more":false}
        """#
        let costs = #"{"object":"page","data":[{"object":"bucket","start_time":\#(todayUTC),"results":[{"object":"organization.costs.result","amount":{"value":0.06,"currency":"usd"}},{"object":"organization.costs.result","amount":{"value":1.5,"currency":"usd"}}]}]}"#
        let snapshot = try OpenAIAPIUsage.snapshot(usageData: Data(usage.utf8), costData: Data(costs.utf8), providerId: "openai-api", displayName: "OpenAI API", now: now)
        XCTAssertEqual(snapshot.spend!, 1.56, accuracy: 0.0001)
        XCTAssertEqual(snapshot.detail.week.tokens.input, 2000, "input is reported uncached")
        XCTAssertEqual(snapshot.detail.week.tokens.cacheRead, 3000)
        XCTAssertEqual(snapshot.detail.week.messages, 12)
        XCTAssertEqual(snapshot.detail.byModel.first?.name, "gpt-5.5")
        XCTAssertEqual(snapshot.periodLabel, "month")
    }

    func testKeychainStoreRoundTrip() throws {
        let account = "test-\(UUID().uuidString)"
        defer { KeychainStore.delete(account: account) }
        XCTAssertNil(try KeychainStore.get(account: account))
        try KeychainStore.set("sk-first", account: account)
        XCTAssertEqual(try KeychainStore.get(account: account), "sk-first")
        try KeychainStore.set("sk-second", account: account)
        XCTAssertEqual(try KeychainStore.get(account: account), "sk-second", "set replaces an existing item")
        KeychainStore.delete(account: account)
        XCTAssertNil(try KeychainStore.get(account: account))
    }

    @MainActor
    func testKeyedProviderRejectsEmptyKeyAndForgets() throws {
        let provider = KeyedProvider(platform: .openRouter)
        XCTAssertEqual(provider.kind, .apiKey)
        XCTAssertThrowsError(try provider.storeKey("   "))
        let account = provider.id
        defer { KeychainStore.delete(account: account) }
        try provider.storeKey(" sk-or-test ")
        XCTAssertEqual(try KeychainStore.get(account: account), "sk-or-test", "keys are trimmed")
        XCTAssertTrue(provider.hasKey)
        provider.forgetKey()
        XCTAssertFalse(provider.hasKey)
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
        let lastWeek = now.addingTimeInterval(-10 * 86400)
        let initial = [
            line(now, id: "a", tokens: 10),
            line(now, id: "a", tokens: 10), // streamed duplicate
            line(yesterday, id: "b", tokens: 5),
            line(lastWeek, id: "z", tokens: 8), // the week before: compared with, not charted
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
        XCTAssertEqual(first.week.tokens.total, 15, "the week is still seven days")
        XCTAssertEqual(first.week.splits.values.reduce(0) { $0 + $1.total }, 15, "the mix is kept per model and project for pricing")
        XCTAssertEqual(first.previousWeek.tokens.total, 8, "the week before is summed separately")
        XCTAssertEqual(first.newestEventDate.map { $0.timeIntervalSince1970.rounded() }, now.timeIntervalSince1970.rounded(), "the newest counted line is when this Mac last did something")

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

    // MARK: Insights

    func testSeverityThresholds() {
        XCTAssertEqual(UsageSeverity.of(nil), .normal)
        XCTAssertEqual(UsageSeverity.of(69), .normal)
        XCTAssertEqual(UsageSeverity.of(70), .warning)
        XCTAssertEqual(UsageSeverity.of(89), .warning)
        XCTAssertEqual(UsageSeverity.of(90), .critical)
        XCTAssertEqual(UsageSeverity.of(100), .critical)
    }

    /// The collapsed surfaces show one reading: the account nearest its limit
    /// (by its peak window), the account with the most room, and the nearest
    /// reset — with a "demo"/"stale" word when the reading is one of those.
    func testHeadroomSummaryPicksTheNearestLimitAndTheRoom() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let us = Locale(identifier: "en_US")
        func snapshot(_ id: String, session: Double?, weekly: Double?, status: UsageStatus = .ok) -> UsageSnapshot {
            var s = UsageSnapshot.empty(providerId: id, displayName: id.capitalized, status: status)
            s.sessionPercent = session
            s.weeklyPercent = weekly
            s.resetsAt = now.addingTimeInterval(2.5 * 3600)
            s.weeklyResetsAt = now.addingTimeInterval(3 * 86400)
            return s
        }
        let empty = HeadroomSummary.of([("claude", "Claude", nil)])
        XCTAssertNil(empty.peak)
        XCTAssertNil(empty.fill, "no figure: the whole line, calm")
        XCTAssertEqual(empty.severity, .normal)
        XCTAssertNil(empty.caption(now: now))
        XCTAssertEqual(empty.spoken(now: now), "AIrail, no usage figures yet")

        let summary = HeadroomSummary.of([
            ("claude", "Claude", snapshot("claude", session: 91, weekly: 40)),
            ("codex", "Codex", snapshot("codex", session: 12, weekly: 30)),
            ("cursor", "Cursor", snapshot("cursor", session: nil, weekly: 75)),
        ])
        XCTAssertEqual(summary.peak?.id, "claude")
        XCTAssertEqual(summary.fill ?? 0, 0.91, accuracy: 0.0001)
        XCTAssertEqual(summary.severity, .critical)
        XCTAssertEqual(summary.room?.id, "codex", "the lowest account under the warning line")
        XCTAssertNil(summary.qualifier)
        XCTAssertEqual(
            summary.caption(now: now, locale: us).map { $0.replacingOccurrences(of: "\u{202F}", with: " ") },
            "Claude 91% · Codex 30% · resets " + UsageFormatting.timeString(now.addingTimeInterval(2.5 * 3600), locale: us).replacingOccurrences(of: "\u{202F}", with: " "),
            "the room account is judged by its own peak window too: Codex's week, not its quiet session"
        )
        XCTAssertTrue(summary.spoken(now: now).hasPrefix("Claude at 91 percent, nearest to its limit; Codex has room at 30 percent; resets "))

        // A spent week outranks a quiet session, and its reset is the weekly one.
        let weekly = HeadroomSummary.of([
            ("claude", "Claude", snapshot("claude", session: 20, weekly: 96)),
            ("codex", "Codex", snapshot("codex", session: 80, weekly: 50)),
        ])
        XCTAssertEqual(weekly.peak?.id, "claude")
        XCTAssertEqual(weekly.peak?.resetsAt, now.addingTimeInterval(3 * 86400))
        XCTAssertNil(weekly.room, "80% is not room")
        XCTAssertTrue(weekly.caption(now: now, locale: us)?.hasSuffix(UsageFormatting.resetString(now.addingTimeInterval(3 * 86400), now: now, locale: us)) == true, "beyond a day the weekday is named")

        let demo = HeadroomSummary.of([("claude", "Claude", snapshot("claude", session: 55, weekly: 10, status: .demo))])
        XCTAssertEqual(demo.qualifier, "demo")
        let stale = HeadroomSummary.of([("claude", "Claude", snapshot("claude", session: 55, weekly: 10, status: .stale))])
        XCTAssertEqual(stale.qualifier, "stale")
        XCTAssertTrue(stale.spoken(now: now).contains("(stale)"))
    }

    /// At the wall the captions count down to the reset of the window that
    /// is spent — the later one if both are — and a limit with no reset date
    /// keeps its "100%".
    func testAtTheWallTheResetIsTheTarget() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let us = Locale(identifier: "en_US")
        var s = UsageSnapshot.empty(providerId: "claude", displayName: "Claude", status: .ok)
        XCTAssertNil(s.atLimitResetsAt)
        s.sessionPercent = 99.7
        s.resetsAt = now.addingTimeInterval(3600)
        s.weeklyPercent = 40
        s.weeklyResetsAt = now.addingTimeInterval(3 * 86400)
        XCTAssertEqual(s.atLimitResetsAt, now.addingTimeInterval(3600), "99.5 and up is the wall the captions already round to")
        s.sessionPercent = 40
        s.weeklyPercent = 100
        XCTAssertEqual(s.atLimitResetsAt, now.addingTimeInterval(3 * 86400), "a spent week with a live session still counts down to the week")
        XCTAssertEqual(s.peakPercent, 100, "and the hairline judges the peak window, not the ring's")
        s.sessionPercent = 100
        XCTAssertEqual(s.atLimitResetsAt, now.addingTimeInterval(3 * 86400), "both spent: the later reset")
        var key = UsageSnapshot.empty(providerId: "openrouter", displayName: "OpenRouter", status: .ok)
        key.weeklyPercent = 100
        XCTAssertNil(key.atLimitResetsAt, "no reset date, no countdown")

        XCTAssertEqual(UsageFormatting.countdown(to: now.addingTimeInterval(72 * 60), now: now, locale: us), "1h 12m")
        XCTAssertEqual(UsageFormatting.countdown(to: now.addingTimeInterval(12 * 86400 + 3 * 3600), now: now, locale: us), "12d 3h")
        XCTAssertEqual(UsageFormatting.countdown(to: now, now: now), "resetting…", "never 0m or a negative span before the next read")
        XCTAssertEqual(UsageFormatting.spokenUsage(s, now: now), "limit reached, resets in " + UsageFormatting.duration(hours: 72))
        XCTAssertEqual(UsageFormatting.spokenUsage(key, now: now), "100 percent used")
        XCTAssertEqual(UsageFormatting.spokenUsage(nil, now: now), "no data")
    }

    /// The ledger keeps counts, never who is signed in, and comes back equal.
    func testUsageLedgerRoundTripsWithoutTheAccount() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("airail-ledger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var snapshot = UsageSnapshot.empty(providerId: "claude", displayName: "Claude", status: .ok)
        snapshot.account = "v@example.com"
        snapshot.sessionPercent = 42
        snapshot.plan = "Max"
        snapshot.lastUpdated = now // ISO 8601 on disk keeps whole seconds
        var usage = UsageAggregate()
        usage.tokens = TokenSplit(input: 10)
        usage.models = ["m": 10]
        usage.splits = [UsageKey(model: "m", project: "p"): TokenSplit(input: 10)]
        snapshot.detail.days = [UsageBucket(start: Calendar.current.startOfDay(for: now), usage: usage)]

        var ledger = UsageLedger()
        ledger.record(snapshot, samples: [PercentSample(date: now, percent: 42)], window: now, now: now)
        XCTAssertNil(ledger.lastSnapshot?.account, "who is signed in never lands on disk")
        XCTAssertEqual(ledger.lastSnapshot?.sessionPercent, 42)
        try await store.save(ledger, for: "claude")
        let reloaded = await store.load("claude")
        let loaded = try XCTUnwrap(reloaded)
        XCTAssertEqual(loaded, ledger)
        XCTAssertEqual(loaded.days.first?.usage.splits[UsageKey(model: "m", project: "p")]?.total, 10)
        let text = try String(contentsOf: directory.appending(path: "claude.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("example.com"))
        await store.delete("claude")
        let afterDelete = await store.load("claude")
        XCTAssertNil(afterDelete)
    }

    /// Copilot has no per-request feed: its chart is the day-to-day difference
    /// of the level AIrail sampled, only across consecutive days, with a
    /// reset making the day's level its usage.
    func testFeedlessLevelsBecomeDailyBuckets() throws {
        let calendar = Calendar.current
        let day0 = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        func day(_ n: Int) throws -> Date { try XCTUnwrap(calendar.date(byAdding: .day, value: n, to: day0)) }
        func level(_ used: Double, resets: Int = 1) throws -> UsageSnapshot {
            var s = UsageSnapshot.empty(providerId: "copilot", displayName: "Copilot", status: .ok)
            s.weeklyUsed = used
            s.weeklyResetsAt = try day(20 + resets)
            return s
        }
        var ledger = UsageLedger()
        XCTAssertTrue(ledger.derivedDays(count: 7, now: try day(0)).isEmpty)
        ledger.recordLevel(try level(100), now: try day(0))
        XCTAssertTrue(ledger.derivedDays(count: 7, now: try day(0)).isEmpty, "one sample is no chart")
        ledger.recordLevel(try level(130), now: try day(1))
        XCTAssertEqual(ledger.derivedDays(count: 7, now: try day(1)).last?.usage.messages, 30)
        ledger.recordLevel(try level(150), now: try day(3)) // day 2 missed: AIrail wasn't running
        XCTAssertEqual(ledger.derivedDays(count: 7, now: try day(3)).last?.usage.messages, 0, "a gap is never spread across the days that were missed")
        ledger.recordLevel(try level(10, resets: 2), now: try day(4)) // the pool reset
        XCTAssertEqual(ledger.derivedDays(count: 7, now: try day(4)).last?.usage.messages, 10, "after a reset the day's level is its usage")
        ledger.recordLevel(try level(25, resets: 2), now: try day(4)) // a later read the same day replaces
        XCTAssertEqual(ledger.derivedDays(count: 7, now: try day(4)).last?.usage.messages, 25)
        XCTAssertEqual(ledger.levels.count, 4)
    }

    /// The Screen Time header compares this week with the one before, only
    /// when there was one; Cursor's feed splits its fortnight the same way.
    func testWeekOverWeek() {
        XCTAssertEqual(UsageFormatting.percentDelta(current: 112, previous: 100), 12)
        XCTAssertEqual(UsageFormatting.percentDelta(current: 50, previous: 100), -50)
        XCTAssertNil(UsageFormatting.percentDelta(current: 50, previous: 0), "nothing to compare with")
        XCTAssertNil(UsageFormatting.percentDelta(current: 50, previous: nil))
        var detail = UsageDetail()
        detail.week.tokens = TokenSplit(input: 1120)
        XCTAssertNil(detail.weekOverWeek)
        detail.previousWeek = UsageAggregate()
        detail.previousWeek?.tokens = TokenSplit(input: 1000)
        XCTAssertEqual(detail.weekOverWeek ?? 0, 12, accuracy: 0.0001)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let report = CursorUsage.Report(percentUsed: 10, autoPercentUsed: nil, apiPercentUsed: nil, autoMessage: nil, apiMessage: nil, cycleStart: nil, cycleEnd: nil, plan: nil)
        let events = [
            CursorUsage.Event(id: "1", date: now.addingTimeInterval(-3600), model: "m", tokens: TokenSplit(input: 300), cents: 1, conversation: nil),
            CursorUsage.Event(id: "2", date: now.addingTimeInterval(-10 * 86400), model: "m", tokens: TokenSplit(input: 200), cents: 1, conversation: nil),
            CursorUsage.Event(id: "3", date: now.addingTimeInterval(-20 * 86400), model: "m", tokens: TokenSplit(input: 999), cents: 1, conversation: nil),
        ]
        let cursor = CursorUsage.detail(events: events, report: report, days: 7, now: now)
        XCTAssertEqual(cursor.week.tokens.total, 300)
        XCTAssertEqual(cursor.previousWeek?.tokens.total, 200, "a fortnight of events: the older week is compared, older still is dropped")
        XCTAssertEqual(cursor.days.count, 7)
        XCTAssertEqual(cursor.weekOverWeek ?? 0, 50, accuracy: 0.0001)
    }

    /// "Used elsewhere": the session figure moving while this Mac's transcripts
    /// didn't. Rule A needs usage in a window with no local line since it
    /// began; rule B needs a rise of three points across two reads with the
    /// newest local line unchanged; local activity or a new window resets both.
    func testUsedElsewhereRules() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func snapshot(_ percent: Double, newest: Date?, activity: Bool = true) -> UsageSnapshot {
            var s = UsageSnapshot.empty(providerId: "claude", displayName: "Claude", status: .ok)
            s.sessionPercent = percent
            s.resetsAt = start.addingTimeInterval(5 * 3600)
            s.sessionWindowLength = 5 * 3600
            s.detail.newestLocalEvent = newest
            if activity { s.detail.week.messages = 12 }
            return s
        }
        var watch: UsageElsewhere.Watch?
        // Rule A: usage in the window, the last local line before it began.
        let quiet = UsageElsewhere.evaluate(snapshot(20, newest: start.addingTimeInterval(-3600)), watch: &watch, now: start.addingTimeInterval(1800))
        XCTAssertEqual(quiet?.kind, .quietWindow)
        XCTAssertEqual(quiet?.summary(tool: "Claude Code"), "No Claude Code activity on this Mac this session")
        XCTAssertNil(UsageElsewhere.evaluate(snapshot(2, newest: start.addingTimeInterval(-3600)), watch: &watch, now: start.addingTimeInterval(1800)), "under three points is noise")
        XCTAssertNil(UsageElsewhere.evaluate(snapshot(20, newest: nil, activity: false), watch: &watch, now: start.addingTimeInterval(1800)), "no transcripts read at all: nothing to say")

        // Rule B: a rise across reads while the newest local line stays put.
        watch = nil
        let local = start.addingTimeInterval(600)
        XCTAssertNil(UsageElsewhere.evaluate(snapshot(40, newest: local), watch: &watch, now: start.addingTimeInterval(700)), "local activity a minute ago keeps resetting the watch")
        XCTAssertNil(UsageElsewhere.evaluate(snapshot(40, newest: local), watch: &watch, now: start.addingTimeInterval(1200)), "the first quiet read is the anchor")
        XCTAssertNil(UsageElsewhere.evaluate(snapshot(42, newest: local), watch: &watch, now: start.addingTimeInterval(1260)), "two points is noise")
        let rose = UsageElsewhere.evaluate(snapshot(45, newest: local), watch: &watch, now: start.addingTimeInterval(1320))
        guard case .rose(let points, let since)? = rose?.kind else { return XCTFail("expected a rise, got \(String(describing: rose))") }
        XCTAssertEqual(points, 5, accuracy: 0.001)
        XCTAssertEqual(since, start.addingTimeInterval(1200))
        XCTAssertTrue(rose?.summary(tool: "Codex", locale: Locale(identifier: "en_GB")).hasPrefix("Up 5 pts since ") == true)
        XCTAssertNil(UsageElsewhere.evaluate(snapshot(46, newest: start.addingTimeInterval(1330)), watch: &watch, now: start.addingTimeInterval(1380)), "the Mac did something: start over")
        XCTAssertNil(UsageElsewhere.evaluate(snapshot(30, newest: local), watch: &watch, now: start.addingTimeInterval(1440)), "a drop starts over too")
        var stale = snapshot(60, newest: local)
        stale.status = .stale
        XCTAssertNil(UsageElsewhere.evaluate(stale, watch: &watch, now: start.addingTimeInterval(1500)))
        XCTAssertNil(watch, "a read that isn't live clears the watch")
    }

    /// Pace is arithmetic on two live numbers and the clock: percent used
    /// against the share of the window that has elapsed.
    func testPaceMath() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let window = DateInterval(start: start, end: start.addingTimeInterval(5 * 3600))
        let pace = try XCTUnwrap(UsagePace.of(percent: 52, window: window, basis: "session", now: start.addingTimeInterval(2 * 3600)))
        XCTAssertEqual(pace.elapsed, 0.4, accuracy: 0.0001)
        XCTAssertEqual(pace.delta, 12, accuracy: 0.0001)
        XCTAssertEqual(pace.remaining, 3 * 3600, accuracy: 0.5)
        XCTAssertEqual(pace.summary, "12 pts above an even pace")
        XCTAssertEqual(UsagePace.of(percent: 30, window: window, basis: "session", now: start.addingTimeInterval(2 * 3600))?.summary, "10 pts under an even pace")
        XCTAssertEqual(UsagePace.of(percent: 41, window: window, basis: "session", now: start.addingTimeInterval(2 * 3600))?.summary, "On an even pace through the session")
        XCTAssertNil(UsagePace.of(percent: 52, window: window, basis: "session", now: window.end), "past the reset there is no pace, not a full arc")
        XCTAssertNil(UsagePace.of(percent: 52, window: window, basis: "session", now: start.addingTimeInterval(-1)))
        XCTAssertNil(UsagePace.of(percent: nil, window: window, basis: "session", now: start))
        XCTAssertNil(UsagePace.of(percent: 52, window: nil, basis: "session", now: start))

        var snapshot = UsageSnapshot.empty(providerId: "claude", displayName: "Claude", status: .ok)
        snapshot.sessionPercent = 52
        snapshot.resetsAt = window.end
        snapshot.sessionWindowLength = 5 * 3600
        snapshot.weeklyPercent = 20
        snapshot.weeklyResetsAt = start.addingTimeInterval(7 * 24 * 3600)
        snapshot.periodStartsAt = start
        XCTAssertEqual(snapshot.sessionWindow, window)
        XCTAssertEqual(snapshot.pace(now: start.addingTimeInterval(2 * 3600))?.basis, "session", "the session window is the one judged when there is one")
        snapshot.sessionPercent = nil
        let weekly = try XCTUnwrap(snapshot.pace(now: start.addingTimeInterval(3.5 * 24 * 3600)))
        XCTAssertEqual(weekly.basis, "weekly")
        XCTAssertEqual(weekly.delta, -30, accuracy: 0.0001, "20% used at half-week is 30 points under")
    }

    /// Every provider states its window bounds from what its service sends:
    /// Codex says the length in seconds, Cursor the cycle's start, Copilot the
    /// reset (a calendar month after the pool began), Claude's is five hours.
    func testWindowsCarryTheirStartAndLength() throws {
        let codex = try CodexUsage.parse(Data(#"""
        {"plan_type":"plus","rate_limit":{
          "primary_window":{"used_percent":40,"limit_window_seconds":18000,"reset_at":1800018000},
          "secondary_window":{"used_percent":20,"limit_window_seconds":604800,"reset_at":1800604800}}}
        """#.utf8))
        XCTAssertEqual(codex.sessionWindowSeconds, 18000)
        XCTAssertEqual(codex.weeklyWindowSeconds, 604800)
        let codexSnapshot = CodexUsage.snapshot(
            report: codex, credential: CodexUsage.Credential(accessToken: "t", accountId: nil, email: nil, plan: nil),
            transcripts: nil, providerId: "codex", displayName: "Codex"
        )
        XCTAssertEqual(codexSnapshot.sessionWindowLength, 18000)
        XCTAssertEqual(codexSnapshot.periodStartsAt?.timeIntervalSince1970, 1_800_000_000)
        XCTAssertEqual(codexSnapshot.sessionWindow?.start.timeIntervalSince1970, 1_800_000_000)

        let cursor = try CursorUsage.parse(Data(#"""
        {"billingCycleStart":"2026-08-25T06:00:19.000Z","billingCycleEnd":"2026-09-25T06:00:19.000Z",
         "membershipType":"pro","individualUsage":{"plan":{"totalPercentUsed":12}}}
        """#.utf8))
        XCTAssertEqual(cursor.cycleStart, DateParsing.iso8601("2026-08-25T06:00:19.000Z"))
        let cursorSnapshot = CursorUsage.snapshot(
            report: cursor, credential: CursorUsage.Credential(userId: "u", accessToken: "t", expiresAt: nil, email: nil, plan: nil),
            detail: UsageDetail(), providerId: "cursor", displayName: "Cursor"
        )
        XCTAssertEqual(cursorSnapshot.periodWindow?.duration ?? 0, 31 * 24 * 3600, accuracy: 1)

        let copilot = try CopilotUsage.parse(Data(#"""
        {"copilot_plan":"pro","quota_reset_date":"2026-10-01",
         "quota_snapshots":{"premium_interactions":{"percent_remaining":50,"unlimited":false,"entitlement":300,"remaining":150}}}
        """#.utf8))
        let copilotSnapshot = CopilotUsage.snapshot(report: copilot, providerId: "copilot", displayName: "Copilot")
        let reset = try XCTUnwrap(copilotSnapshot.weeklyResetsAt)
        let began = try XCTUnwrap(copilotSnapshot.periodStartsAt)
        XCTAssertEqual(Calendar.current.dateComponents([.month], from: began, to: reset).month, 1)
    }

    func testDurationFormatting() {
        let us = Locale(identifier: "en_US")
        let gb = Locale(identifier: "en_GB")
        XCTAssertEqual(UsageFormatting.duration(hours: 0.5, locale: us), "30m")
        XCTAssertEqual(UsageFormatting.duration(hours: 2.4, locale: us), "2h 24m")
        XCTAssertEqual(UsageFormatting.duration(hours: 2.4, locale: gb), "2h 24m")
        XCTAssertEqual(UsageFormatting.duration(hours: 26, locale: us), "26h", "hours and minutes until two days")
        XCTAssertEqual(UsageFormatting.duration(hours: 72, locale: us), "3d")
        XCTAssertEqual(UsageFormatting.duration(hours: 0.001, locale: us), "1m", "a limit seconds away never reads 0m")
    }

    /// Reset and clock strings follow the locale's clock and day-month order,
    /// like the Battery pane; a US Mac reads "9:00 AM", a British one "09:00".
    func testResetAndClockStringsFollowTheLocale() throws {
        let us = Locale(identifier: "en_US")
        let gb = Locale(identifier: "en_GB")
        let calendar = Calendar.current
        // Foundation sets AM/PM off with a narrow no-break space; compare on plain spaces.
        func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 12)))
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 9)))
        XCTAssertEqual(plain(UsageFormatting.resetString(monday, now: now, locale: us)), "resets Mon 9:00 AM")
        XCTAssertEqual(UsageFormatting.resetString(monday, now: now, locale: gb), "resets Mon 09:00")
        let october = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 9)))
        XCTAssertEqual(UsageFormatting.resetString(october, now: now, locale: us), "resets Oct 1")
        XCTAssertEqual(UsageFormatting.resetString(october, now: now, locale: gb), "resets 1 Oct")
        let afternoon = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 14, minute: 32)))
        XCTAssertEqual(plain(UsageFormatting.clockString(afternoon, now: now, locale: us)), "at 2:32 PM")
        XCTAssertEqual(UsageFormatting.clockString(afternoon, now: now, locale: gb), "at 14:32")
        XCTAssertEqual(UsageFormatting.currentMonthAbbreviation(october, locale: us), "OCT")
    }

    func testAPIValueEstimateApportionsTheWeekByModel() throws {
        var week = UsageAggregate()
        // Mostly cheap cache reads: opus 5/25/6.25/0.5 per Mtok → $23.125,
        // haiku 1/5/1.25/0.1 → $4.625; three quarters opus, one quarter haiku.
        week.tokens = TokenSplit(input: 1_000_000, output: 200_000, cacheWrite: 500_000, cacheRead: 20_000_000)
        week.models = ["claude-opus-4-8": 16_275_000, "claude-haiku-4-5": 5_425_000]
        let dollars = try XCTUnwrap(ModelPricing.estimate(week))
        XCTAssertEqual(dollars, 0.75 * 23.125 + 0.25 * 4.625, accuracy: 0.001)

        week.models = [:]
        XCTAssertEqual(ModelPricing.estimate(week), TokenPrices.unlisted.cost(of: week.tokens), "no model breakdown → the unlisted rate")
        XCTAssertNil(ModelPricing.estimate(UsageAggregate()), "no tokens → no estimate")
    }

    /// With the mix kept per model and project, each model is priced on its
    /// own split, projects sum the models used in them, and a provider's own
    /// per-model money is shown as its figure rather than an estimate.
    func testCostByModelAndProjectUsesEachModelsOwnMix() throws {
        var week = UsageAggregate()
        let opusInApp = TokenSplit(input: 1_000_000, output: 100_000)        // opus 5/25 → $7.50
        let haikuInApp = TokenSplit(input: 2_000_000, output: 200_000)       // haiku 1/5 → $3.00
        let opusInDotfiles = TokenSplit(cacheRead: 10_000_000)               // opus 0.5 → $5.00
        week.splits = [
            UsageKey(model: "claude-opus-4-8", project: "app"): opusInApp,
            UsageKey(model: "claude-haiku-4-5", project: "app"): haikuInApp,
            UsageKey(model: "claude-opus-4-8", project: "dotfiles"): opusInDotfiles,
        ]
        week.tokens = opusInApp + haikuInApp + opusInDotfiles
        week.models = ["claude-opus-4-8": opusInApp.total + opusInDotfiles.total, "claude-haiku-4-5": haikuInApp.total]
        week.projects = ["app": opusInApp.total + haikuInApp.total, "dotfiles": opusInDotfiles.total]

        XCTAssertEqual(try XCTUnwrap(ModelPricing.estimate(week)), 15.5, accuracy: 0.001, "the sum of each model's own split, not the blended mix")
        let byModel = ModelPricing.estimateByModel(week)
        XCTAssertEqual(byModel["claude-opus-4-8"] ?? 0, 12.5, accuracy: 0.001)
        XCTAssertEqual(byModel["claude-haiku-4-5"] ?? 0, 3, accuracy: 0.001)
        let byProject = ModelPricing.estimateByProject(week)
        XCTAssertEqual(byProject["app"] ?? 0, 10.5, accuracy: 0.001)
        XCTAssertEqual(byProject["dotfiles"] ?? 0, 5, accuracy: 0.001)

        var detail = UsageDetail(week: week)
        XCTAssertEqual(detail.byModel.first?.name, "claude-opus-4-8")
        XCTAssertEqual(detail.byModel.first?.cost ?? 0, 12.5, accuracy: 0.001)
        XCTAssertTrue(detail.byModel.first?.costIsEstimate == true)
        XCTAssertEqual(detail.byProject.map(\.name), ["dotfiles", "app"], "by tokens, and the cache-heavy project has more of them")
        XCTAssertEqual(detail.byProject.first?.cost ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(detail.byProject.last?.cost ?? 0, 10.5, accuracy: 0.001)

        // Cursor keeps real cents per model: shown as its figure, not an estimate.
        detail.week.costs["claude-opus-4-8"] = 9.99
        let cursorRow = try XCTUnwrap(detail.byModel.first { $0.name == "claude-opus-4-8" })
        XCTAssertEqual(cursorRow.cost, 9.99)
        XCTAssertFalse(cursorRow.costIsEstimate)

        var merged = UsageAggregate()
        merged.merge(week)
        merged.merge(week)
        XCTAssertEqual(merged.splits[UsageKey(model: "claude-opus-4-8", project: "app")]?.total, opusInApp.total * 2, "splits add up across buckets")
    }

    /// A reply that parses as JSON but lacks the keys a parser needs is the
    /// endpoint moving, not the sign-in failing: every guard names the keys
    /// it saw, and the error is transient.
    func testMissingKeysAreReportedAsShapeDrift() {
        func drift(_ block: () throws -> Any) -> ConnectionError? {
            do { _ = try block(); return nil } catch { return error as? ConnectionError }
        }
        let odd = Data(#"{"zeta":1,"alpha":{"x":2}}"#.utf8)
        let cases: [(String, () throws -> Any)] = [
            ("Claude Code", { try ClaudeUsage.parse(odd) }),
            ("Codex", { try CodexUsage.parse(odd) }),
            ("Cursor", { try CursorUsage.parse(odd) }),
            ("GitHub", { try CopilotUsage.parse(odd) }),
            ("OpenRouter", { try OpenRouterUsage.snapshot(keyData: odd, creditsData: nil, providerId: "openrouter", displayName: "OpenRouter") }),
            ("DeepSeek", { try DeepSeekUsage.snapshot(data: odd, providerId: "deepseek", displayName: "DeepSeek") }),
        ]
        for (tool, block) in cases {
            guard case .shapeChanged(let named, let detail)? = drift(block) else {
                return XCTFail("\(tool) did not report shape drift")
            }
            XCTAssertEqual(named, tool)
            XCTAssertEqual(detail, "keys: alpha, zeta", "\(tool) names the keys it saw, sorted")
        }
        XCTAssertEqual(JSONObject([:]).keyNames, "keys: none")
    }

    /// What Report a Problem and Save Diagnostics hand over never carries a
    /// home path, an email or anything shaped like a token.
    func testDiagnosticsRedaction() {
        let home = "/Users/vincent"
        let text = """
        Transcript root: /Users/vincent/.claude/projects, also /Users/vincent/Desktop
        Signed in as vincent@example.com and ops.team+ai@sub.example.org
        Authorization: Bearer sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnop
        token gho_1234567890abcdefghijklmnopqrstuvwxyz
        claude: live, read 2m ago, 42%
        """
        let redacted = Diagnostics.redact(text, home: home)
        XCTAssertFalse(redacted.contains(home))
        XCTAssertFalse(redacted.contains("@"))
        XCTAssertFalse(redacted.contains("sk-ant"))
        XCTAssertFalse(redacted.contains("gho_"))
        XCTAssertTrue(redacted.contains("~/.claude/projects"))
        XCTAssertTrue(redacted.contains("<email>"))
        XCTAssertTrue(redacted.contains("<redacted>"))
        XCTAssertTrue(redacted.contains("claude: live, read 2m ago, 42%"), "the useful lines survive")
        XCTAssertEqual(Diagnostics.issueURL(summary: "a b").query?.contains("template=bug.yml"), true)
    }

    /// The fixture tooling: a document's key paths, and a redacted copy that
    /// keeps the shape and the plan/model/date strings but nothing personal.
    func testJSONShapePathsAndRedaction() throws {
        let object: [String: Any] = [
            "rate_limit": ["primary_window": ["used_percent": 40, "reset_at": 1]],
            "email": "v@example.com", "plan_type": "plus",
            "items": [["id": "x", "model": "m"]],
        ]
        let paths = JSONShape.paths(of: object)
        XCTAssertTrue(paths.isSuperset(of: ["rate_limit", "rate_limit.primary_window.used_percent", "items[].model", "email"]), "\(paths)")
        let redacted = try XCTUnwrap(JSONShape.redacted(object) as? [String: Any])
        XCTAssertEqual(redacted["email"] as? String, "…")
        XCTAssertEqual(redacted["plan_type"] as? String, "plus")
        let items = try XCTUnwrap(redacted["items"] as? [[String: Any]])
        XCTAssertEqual(items.first?["id"] as? String, "…")
        XCTAssertEqual(items.first?["model"] as? String, "m")
        XCTAssertEqual(JSONShape.paths(of: JSONShape.redacted(object)), paths, "redaction keeps the shape")
        XCTAssertEqual(
            JSONShape.fixtureURL(for: URL(string: "https://api.anthropic.com/api/oauth/usage")!).lastPathComponent,
            "api.anthropic.com_api_oauth_usage.json"
        )
    }

    /// A populated per-model weekly bucket becomes a meter under the ring; a
    /// null one (Opus on a Max account today) is nothing, never 0%.
    func testClaudePerModelWeeklyBucketBecomesAMeter() throws {
        let json = #"""
        {"five_hour":{"utilization":2.0,"resets_at":"2026-09-02T09:30:00.479395+00:00"},
         "seven_day":{"utilization":31.5,"resets_at":"2026-09-08T02:00:00.479420+00:00"},
         "seven_day_opus":null,
         "seven_day_sonnet":{"utilization":12.5,"resets_at":"2026-09-08T02:00:00.479420+00:00"}}
        """#
        let report = try ClaudeUsage.parse(Data(json.utf8))
        XCTAssertEqual(report.modelMeters.map(\.name), ["Sonnet this week"])
        XCTAssertEqual(report.modelMeters.first?.percent, 12.5)
        let snapshot = ClaudeUsage.snapshot(
            report: report, credential: ClaudeUsage.Credential(accessToken: "t", expiresAt: nil, plan: "Max"),
            transcripts: nil, providerId: "claude", displayName: "Claude"
        )
        XCTAssertEqual(snapshot.detail.meters.map(\.name), ["Sonnet this week"])
    }

    func testModelPricingPicksTheMostSpecificRow() {
        // A version with its own price beats its family row — and only that version.
        XCTAssertEqual(ModelPricing.prices(for: "claude-opus-4-1-20250805").input, 15)
        XCTAssertEqual(ModelPricing.prices(for: "claude-opus-4-20250514").input, 15)
        XCTAssertEqual(ModelPricing.prices(for: "claude-opus-4-8").input, 5)
        XCTAssertEqual(ModelPricing.prices(for: "anthropic/claude-opus-5:batch").input, 5)
        XCTAssertEqual(ModelPricing.prices(for: "claude-3-5-haiku-20241022").input, 1)
        XCTAssertEqual(ModelPricing.prices(for: "gpt-5-mini").input, 0.25)
        XCTAssertEqual(ModelPricing.prices(for: "gpt-5.2-codex").input, 1.75)
        XCTAssertEqual(ModelPricing.prices(for: "gpt-5.5-mini").input, 1.25, "an unknown 5.x reads as the gpt-5 row")
        // Aliases and cheap variants: each new row must beat its family row.
        XCTAssertEqual(ModelPricing.prices(for: "claude-opus-4.0").input, 15, "opus-4.0 is Opus 4, not today's Opus")
        XCTAssertEqual(ModelPricing.prices(for: "claude-4-opus-20250514").input, 15, "version-first Opus 4 spelling")
        XCTAssertEqual(ModelPricing.prices(for: "claude-4.1-opus").input, 15, "version-first Opus 4.1 spelling")
        XCTAssertEqual(ModelPricing.prices(for: "gpt-4.1-mini").input, 0.4, "gpt-4.1-mini must not price as gpt-4.1")
        XCTAssertEqual(ModelPricing.prices(for: "gpt-4o-mini-2024-07-18").input, 0.15, "gpt-4o-mini must not price as gpt-4o")
        XCTAssertEqual(ModelPricing.prices(for: "o3-mini").input, 1.1, "o3-mini must not price as o3")
        XCTAssertEqual(ModelPricing.prices(for: "o3-pro").input, 20, "o3-pro must not price as o3")
        XCTAssertEqual(ModelPricing.prices(for: "o3-2025-04-16").input, 2, "a dated o3 is still the o3 row")
        // Keys fit anywhere at a boundary (Cursor's ids), never inside a word.
        XCTAssertEqual(ModelPricing.prices(for: "cursor-grok-4.6-high-fast").input, 3)
        XCTAssertEqual(ModelPricing.prices(for: "gemini-3-pro").input, 2, "a bare family id is the family row, not a longer sibling")
        XCTAssertEqual(ModelPricing.prices(for: "chatgpt-4o-latest"), .unlisted)
        XCTAssertEqual(ModelPricing.prices(for: "auto"), .unlisted)
    }

    func testPriceTableIsWellFormed() {
        let keys = ModelPricing.table.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "duplicate keys")
        for row in ModelPricing.table {
            XCTAssertEqual(row.key, ModelPricing.normalize(row.key), "\(row.key) is not in normalized form")
            XCTAssertGreaterThan(row.prices.input, 0, row.key)
            XCTAssertGreaterThan(row.prices.output, row.prices.input, "\(row.key): output should cost more than input")
            XCTAssertGreaterThanOrEqual(row.prices.cacheWrite, row.prices.input, "\(row.key): a cache write is at least an input token")
            XCTAssertLessThan(row.prices.cacheRead, row.prices.input, "\(row.key): a cache read is the discount")
        }
    }

    func testModelIdNormalization() {
        XCTAssertEqual(ModelPricing.normalize("anthropic/claude-opus-4.8:batch"), "claude-opus-4.8")
        XCTAssertEqual(ModelPricing.normalize("claude-opus-4-8"), "claude-opus-4.8")
        XCTAssertEqual(ModelPricing.normalize("openai/gpt-5.5"), "gpt-5.5")
        XCTAssertEqual(ModelPricing.normalize("claude-fable-5"), "claude-fable-5")
    }

    @MainActor
    func testUpdateVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("0.2.1", than: "0.2.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0", than: "0.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("0.2.0", than: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.9", than: "0.2.0"))
    }

    @MainActor
    func testReleaseParsePicksTheDmgAndThePage() throws {
        let body = """
        {"tag_name": "v0.2.1",
         "html_url": "https://github.com/Vincentj88-python/AIrail/releases/tag/v0.2.1",
         "body": "Quieter update check.",
         "assets": [
           {"name": "AIrail-0.2.1.dmg.sha256",
            "browser_download_url": "https://github.com/Vincentj88-python/AIrail/releases/download/v0.2.1/AIrail-0.2.1.dmg.sha256"},
           {"name": "AIrail-0.2.1.dmg",
            "browser_download_url": "https://github.com/Vincentj88-python/AIrail/releases/download/v0.2.1/AIrail-0.2.1.dmg"}
         ]}
        """
        let release = try XCTUnwrap(UpdateChecker.parse(Data(body.utf8)))
        XCTAssertEqual(release.version, "0.2.1")
        XCTAssertEqual(release.notes, "Quieter update check.")
        XCTAssertEqual(release.page.absoluteString, "https://github.com/Vincentj88-python/AIrail/releases/tag/v0.2.1")
        XCTAssertEqual(release.dmg?.absoluteString, "https://github.com/Vincentj88-python/AIrail/releases/download/v0.2.1/AIrail-0.2.1.dmg")

        // No tag (a 404 body while the repo is private) is no release; a tag
        // with nothing attached is a release whose page is the listing.
        XCTAssertNil(try UpdateChecker.parse(Data(#"{"message": "Not Found"}"#.utf8)))
        let bare = try XCTUnwrap(UpdateChecker.parse(Data(#"{"tag_name": "0.3.0"}"#.utf8)))
        XCTAssertEqual(bare.version, "0.3.0")
        XCTAssertNil(bare.dmg)
        XCTAssertEqual(bare.page, UpdateChecker.releasesPage)
    }

    @MainActor
    func testUpdateNotificationCarriesItsLinksAndTheResponseFollowsThem() throws {
        let page = try XCTUnwrap(URL(string: "https://github.com/Vincentj88-python/AIrail/releases/tag/v0.2.1"))
        let dmg = try XCTUnwrap(URL(string: "https://github.com/Vincentj88-python/AIrail/releases/download/v0.2.1/AIrail-0.2.1.dmg"))
        let release = UpdateChecker.Release(version: "0.2.1", notes: "", page: page, dmg: dmg)

        let request = UpdateChecker.notificationRequest(for: release, current: "0.2.0")
        XCTAssertEqual(request.identifier, "update", "a newer release replaces the earlier notification, never stacks")
        XCTAssertNil(request.trigger)
        XCTAssertNil(request.content.sound)
        XCTAssertEqual(request.content.categoryIdentifier, UpdateChecker.notificationCategory.identifier)
        XCTAssertEqual(request.content.body, "AIrail 0.2.1 is available — you have 0.2.0.")
        XCTAssertEqual(UpdateChecker.notificationCategory.actions.map(\.identifier), [UpdateChecker.downloadActionIdentifier])

        // The Download button opens the DMG, a plain click the release page.
        let userInfo = request.content.userInfo
        XCTAssertEqual(UpdateChecker.destination(for: UpdateChecker.downloadActionIdentifier, in: userInfo), dmg)
        XCTAssertEqual(UpdateChecker.destination(for: UNNotificationDefaultActionIdentifier, in: userInfo), page)
        XCTAssertNil(UpdateChecker.destination(for: UNNotificationDismissActionIdentifier, in: userInfo), "dismissing it opens nothing")

        // Only a DMG served from github.com is ever opened; anything else is the page.
        var elsewhere = userInfo
        elsewhere["dmg"] = "https://example.com/AIrail-0.2.1.dmg"
        XCTAssertEqual(UpdateChecker.destination(for: UpdateChecker.downloadActionIdentifier, in: elsewhere), page)
        let noDmg = UpdateChecker.Release(version: "0.2.1", notes: "", page: page, dmg: nil)
        let bare = UpdateChecker.notificationRequest(for: noDmg, current: "0.2.0")
        XCTAssertEqual(UpdateChecker.destination(for: UpdateChecker.downloadActionIdentifier, in: bare.content.userInfo), page)
    }

    @MainActor
    func testUpdateMenuTitleNamesTheRelease() throws {
        XCTAssertEqual(UpdateChecker.menuTitle(for: nil), "Check for Updates…")
        let release = UpdateChecker.Release(version: "0.2.1", notes: "", page: UpdateChecker.releasesPage, dmg: nil)
        XCTAssertEqual(UpdateChecker.menuTitle(for: release), "Update to 0.2.1…")
    }

    func testBuildLabelShowsCommitOnlyWhenStamped() {
        XCTAssertEqual(BuildInfo.label(version: "0.2.0", commit: nil), "0.2.0")
        XCTAssertEqual(BuildInfo.label(version: "0.2.0", commit: "0a744d2"), "0.2.0 (0a744d2)")
        XCTAssertEqual(BuildInfo.label(version: "0.2.0", commit: "0a744d2-dirty"), "0.2.0 (0a744d2-dirty)")
        XCTAssertNil(BuildInfo.commit, "only release.sh stamps AIrailCommit; a test host has none")
    }

    // MARK: Network path

    func testTestHostIsRecognisedByAnyXCTestKey() {
        XCTAssertTrue(LaunchOptions.isRunningTests, "this run: the host app must not start its readers or the update check")
        for key in ["XCTestSessionIdentifier", "XCTestBundlePath", "XCTestConfigurationFilePath"] {
            XCTAssertTrue(LaunchOptions.isRunningTests(in: [key: "x"]), key)
        }
        XCTAssertFalse(LaunchOptions.isRunningTests(in: ["PATH": "/usr/bin"]))
    }

    func testNetworkSessionKeepsNothingOnDisk() {
        let configuration = HTTPClient.configuration
        XCTAssertNil(configuration.urlCache, "no URL cache: a usage body never lands in ~/Library/Caches")
        XCTAssertNil(configuration.httpCookieStorage, "no cookie jar: an edge-gateway cookie never lands in HTTPStorages")
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertEqual(configuration.httpAdditionalHeaders?["User-Agent"] as? String, "AIrail")
        XCTAssertTrue(configuration.waitsForConnectivity)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 30)
    }

    @MainActor
    func testEveryEndpointIsOnTheAllowlist() throws {
        // The providers' own URL constants, not re-typed copies, so a changed
        // endpoint is caught here: every one the providers hit, plus the release check.
        let endpoints = [
            ClaudeProvider.usageURL,
            CodexProvider.usageURL,
            CopilotProvider.quotaURL,
            CursorProvider.usageURL, CursorProvider.eventsURL,
            OpenRouterUsage.keyURL, OpenRouterUsage.creditsURL,
            DeepSeekUsage.balanceURL,
            AnthropicAPIUsage.usageURL(now: .now), AnthropicAPIUsage.costURL(now: .now),
            OpenAIAPIUsage.usageURL(now: .now), OpenAIAPIUsage.costURL(now: .now),
            UpdateChecker.latestReleaseURL,
        ]
        for url in endpoints {
            XCTAssertTrue(HTTPClient.isAllowed(url), url.absoluteString)
            XCTAssertNoThrow(try HTTPClient.check(url), url.absoluteString)
        }
        XCTAssertEqual(HTTPClient.allowedHosts.count, 7, "README says seven hosts; keep the two in step")
        XCTAssertEqual(Set(endpoints.compactMap { $0.host() }), HTTPClient.allowedHosts, "no host on the list without an endpoint that uses it")
    }

    func testOffListHostsAreRefusedBeforeAnyRequest() async throws {
        XCTAssertTrue(HTTPClient.hasRedirectGuard, "a redirect off the list must be refused by the session's delegate")
        // What the error names: the host when the host is the problem, the
        // scheme (and port) with it when the host is allowed but reached wrongly.
        let blocked = [
            ("https://example.com/usage", "example.com"),                                    // not on the list
            ("http://api.anthropic.com/api/oauth/usage", "http://api.anthropic.com"),       // not https
            ("https://api.anthropic.com:8443/usage", "https://api.anthropic.com:8443"),     // not the default port
            ("https://evil.api.anthropic.com/usage", "evil.api.anthropic.com"),             // a subdomain is another host
        ]
        for (text, named) in blocked {
            let url = try XCTUnwrap(URL(string: text))
            XCTAssertFalse(HTTPClient.isAllowed(url), text)
            XCTAssertEqual(HTTPClient.blockedName(url), named, text)
            XCTAssertThrowsError(try HTTPClient.check(url), text) { error in
                guard let failure = error as? ConnectionError, case .blockedHost(let host) = failure else {
                    return XCTFail("\(text): \(error)")
                }
                XCTAssertEqual(host, named, "\(text) must never blame a bare allowed host")
            }
        }
        XCTAssertFalse(HTTPClient.isAllowed(nil))

        // The guard runs before a task exists, so this never touches the network.
        do {
            _ = try await HTTPClient.get(try XCTUnwrap(URL(string: "https://example.com/")), headers: [:])
            XCTFail("an off-list GET must throw")
        } catch let failure as ConnectionError {
            guard case .blockedHost(let host) = failure else { return XCTFail("\(failure)") }
            XCTAssertEqual(host, "example.com")
            XCTAssertFalse(failure.isTransient, "a wrong host is a bug in AIrail, not something a retry fixes")
            XCTAssertEqual(failure.shortDescription, "Host not on AIrail's list")
        }
    }

    func testLegacyStoreScrubRemovesOnlyTheV020Artefacts() throws {
        let manager = FileManager.default
        let library = manager.temporaryDirectory.appending(path: "airail-scrub-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: library) }
        let id = "com.example.airail-test"
        let cacheDirectory = library.appending(path: "Caches/\(id)")
        let legacy = [
            cacheDirectory.appending(path: "Cache.db"),
            cacheDirectory.appending(path: "Cache.db-shm"),
            cacheDirectory.appending(path: "Cache.db-wal"),
            cacheDirectory.appending(path: "fsCachedData/0A1B2C3D"),
            library.appending(path: "HTTPStorages/\(id).binarycookies"),
        ]
        let kept = [
            cacheDirectory.appending(path: "something-else.plist"),
            library.appending(path: "HTTPStorages/\(id)/httpstorages.sqlite"),
        ]
        for file in legacy + kept {
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: file)
        }

        HTTPClient.removeLegacyStores(bundleId: id, library: library)

        for file in legacy {
            XCTAssertFalse(manager.fileExists(atPath: file.path), file.lastPathComponent)
        }
        XCTAssertFalse(manager.fileExists(atPath: cacheDirectory.appending(path: "fsCachedData").path), "the body-file directory goes")
        XCTAssertTrue(manager.fileExists(atPath: cacheDirectory.path), "only the artefacts go, not the directory")
        for file in kept {
            XCTAssertTrue(manager.fileExists(atPath: file.path), "\(file.lastPathComponent) is not v0.2.0's and stays")
        }
        HTTPClient.removeLegacyStores(bundleId: id, library: library) // a no-op once gone
        HTTPClient.removeLegacyStores(bundleId: nil, library: library)
        for file in kept {
            XCTAssertTrue(manager.fileExists(atPath: file.path))
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
