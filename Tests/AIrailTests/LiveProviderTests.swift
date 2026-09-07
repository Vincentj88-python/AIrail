import XCTest
@testable import AIrail

/// Opt-in smoke tests against the sign-ins actually present on this Mac.
/// Skipped unless `AIRAIL_LIVE=1` (`TEST_RUNNER_AIRAIL_LIVE=1 xcodebuild test …`),
/// because they hit real endpoints and depend on which tools are installed.
final class LiveProviderTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AIRAIL_LIVE"] == "1", "set AIRAIL_LIVE=1 to run")
    }

    @MainActor
    func testCodexLiveRead() async throws {
        let provider = CodexProvider()
        try XCTSkipUnless(provider.isInstalled(), "Codex not installed")
        let snapshot = try await provider.fetchUsage()
        print("codex:", describe(snapshot))
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertNotNil(snapshot.ringPercent)
        XCTAssertEqual(snapshot.detail.days.count, 7)
    }

    @MainActor
    func testCopilotLiveRead() async throws {
        let provider = CopilotProvider()
        try XCTSkipUnless(provider.isInstalled(), "gh not installed")
        let snapshot = try await provider.fetchUsage()
        print("copilot:", describe(snapshot))
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertNotNil(snapshot.plan)
    }

    @MainActor
    func testCursorLiveRead() async throws {
        let provider = CursorProvider()
        try XCTSkipUnless(provider.isInstalled(), "Cursor not installed")
        let snapshot = try await provider.fetchUsage()
        print("cursor:", describe(snapshot))
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertNotNil(snapshot.weeklyPercent)
    }

    /// Keyed platforms run only when a key is in the environment, e.g.
    /// `TEST_RUNNER_AIRAIL_OPENROUTER_KEY=sk-or-… xcodebuild test …`.
    @MainActor
    func testKeyedPlatformsLiveRead() async throws {
        let env = ProcessInfo.processInfo.environment
        let keys: [(KeyedPlatform, String)] = [
            (.openRouter, "AIRAIL_OPENROUTER_KEY"),
            (.deepSeek, "AIRAIL_DEEPSEEK_KEY"),
            (.anthropicAPI, "AIRAIL_ANTHROPIC_ADMIN_KEY"),
            (.openAIAPI, "AIRAIL_OPENAI_ADMIN_KEY"),
        ]
        var ran = 0
        for (platform, variable) in keys {
            guard let key = env[variable], !key.isEmpty else { continue }
            ran += 1
            let snapshot = try await platform.fetch(key, platform.id, platform.displayName)
            print("\(platform.id):", describe(snapshot))
            XCTAssertEqual(snapshot.status, .ok)
        }
        try XCTSkipIf(ran == 0, "no AIRAIL_*_KEY variables set")
    }

    /// The Keychain half of the Claude provider prompts the user, so only the
    /// transcript scan runs here — mainly to see what a first scan costs.
    func testClaudeTranscriptScanIsFastEnough() async throws {
        let root = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root.path), "no Claude Code transcripts")
        let scanner = TranscriptScanner(roots: [root], requiredSubstrings: ["\"assistant\""], extractor: ClaudeUsage.transcriptEvent)

        let start = Date()
        let first = try await scanner.summary()
        let firstScan = Date().timeIntervalSince(start)
        let again = Date()
        let second = try await scanner.summary()
        let rescan = Date().timeIntervalSince(again)
        let detail = UsageDetail(hours: first.hours, days: first.days, week: first.week)
        print("claude transcripts: first scan \(String(format: "%.2f", firstScan))s, rescan \(String(format: "%.3f", rescan))s")
        print("  daily tokens \(first.days.map { Int($0.usage.tokens.total) }) hourly messages \(first.hours.map { $0.usage.messages })")
        print("  models \(detail.byModel.prefix(4).map { "\(UsageFormatting.modelDisplayName($0.name)) \(UsageFormatting.compactTokens($0.tokens))" })")
        print("  projects \(detail.byProject.prefix(3).map { "\($0.name) \(UsageFormatting.compactTokens($0.tokens))" }) tools \(detail.topTools.prefix(3).map { "\($0.name) \($0.count)" })")
        print("  week: \(first.week.messages) requests, \(first.week.sessions.count) sessions, thinking \(first.week.thinkingShare ?? 0)")

        XCTAssertEqual(first.days.count, 7)
        XCTAssertEqual(first.hours.count, 24)
        XCTAssertEqual(first.days, second.days, "a rescan with no new data must not change totals")
        XCTAssertLessThan(rescan, 0.5, "incremental rescans must be cheap")
    }

    private func describe(_ s: UsageSnapshot) -> String {
        "plan=\(s.plan ?? "-") session=\(s.sessionPercent.map { "\($0)%" } ?? "-") "
            + "\(s.periodLabel)=\(s.weeklyPercent.map { "\($0)%" } ?? "-") used=\(s.weeklyUsed ?? -1)/\(s.weeklyLimit ?? -1) "
            + "resets=\(s.resetsAt?.description ?? "-") \(s.periodLabel)Resets=\(s.weeklyResetsAt?.description ?? "-") "
            + "history=\(s.detail.days.map { Int($0.usage.tokens.total) }) account=\(s.account.map { _ in "<set>" } ?? "-") "
            + "models=\(s.detail.byModel.prefix(3).map { "\($0.name):\(UsageFormatting.compactTokens($0.tokens))" }) "
            + "meters=\(s.detail.meters.map { "\($0.name):\($0.percent.map { Int($0) } ?? -1)" }) "
            + "hours=\(s.detail.hours.count) week=\(s.detail.week.messages)req"
    }
}
