import SwiftUI
import UserNotifications
import XCTest
@testable import AIrail

/// ProviderManager driven by scripted providers: no sign-in, no network, no
/// Keychain prompt, and a clock the test moves instead of sleeping through
/// a backoff.
final class ProviderManagerTests: XCTestCase {

    // MARK: Single flight

    @MainActor
    func testRefreshJoinsTheReadInFlight() async throws {
        let fake = FakeProvider(id: "claude", results: [.success(Self.snapshot("claude", percent: 42))])
        let (manager, settings) = try makeManager([fake])
        settings.connect("claude")
        fake.holdsReads = true

        let timer = Task { await manager.refresh("claude") }
        let button = Task { await manager.refresh("claude", force: true) }
        await eventually("the first read to start") { fake.reads == 1 }
        XCTAssertTrue(manager.refreshingIds.contains("claude"))

        fake.release()
        await timer.value
        await button.value
        XCTAssertEqual(fake.reads, 1, "a forced refresh joins the read in flight instead of starting or cancelling one")
        XCTAssertEqual(manager.snapshots["claude"]?.sessionPercent, 42)
        XCTAssertEqual(manager.snapshots["claude"]?.status, .ok)
        XCTAssertTrue(manager.refreshingIds.isEmpty)
    }

    @MainActor
    func testDisconnectDropsTheReadInFlight() async throws {
        let claude = FakeProvider(id: "claude", results: [.success(Self.snapshot("claude", percent: 42))])
        let codex = FakeProvider(id: "codex", results: [.success(Self.snapshot("codex", percent: 7))])
        let (manager, settings) = try makeManager([claude, codex])
        settings.connect("claude")
        settings.connect("codex") // so removing Claude doesn't fall back to demo
        claude.holdsReads = true

        let refresh = Task { await manager.refresh("claude") }
        await eventually("the read to start") { claude.reads == 1 }
        manager.disconnect("claude")
        XCTAssertFalse(settings.isConnected("claude"))

        claude.release()
        await refresh.value
        XCTAssertNil(manager.snapshots["claude"], "a read that lands after its account is removed writes nothing")
        XCTAssertNil(manager.lastErrors["claude"], "nor does the 'cancelled' error it throws")
        XCTAssertTrue(manager.refreshingIds.isEmpty)
    }

    // MARK: Backoff

    @MainActor
    func testForceBypassesTheBackoffTheTimerHonours() async throws {
        let fake = FakeProvider(id: "claude", results: [
            .failure(.network("offline")),
            .success(Self.snapshot("claude", percent: 42)),
        ])
        let (manager, settings) = try makeManager([fake])
        settings.connect("claude")

        await manager.refresh("claude")
        XCTAssertEqual(fake.reads, 1)
        XCTAssertEqual(manager.lastErrors["claude"]?.shortDescription, "Couldn't reach service")
        await manager.refresh("claude")
        XCTAssertEqual(fake.reads, 1, "the timer waits out the backoff")
        await manager.refresh("claude", force: true)
        XCTAssertEqual(fake.reads, 2, "the Refresh button doesn't")
        XCTAssertNil(manager.lastErrors["claude"])
        XCTAssertEqual(manager.snapshots["claude"]?.status, .ok)
        await manager.refresh("claude")
        XCTAssertEqual(fake.reads, 3, "a success clears the backoff")
    }

    @MainActor
    func testBackoffGrowsWithTheStreakAndHonoursRetryAfter() async throws {
        let clock = TestClock()
        let fake = FakeProvider(id: "codex", results: [.failure(.network("offline"))])
        let (manager, settings) = try makeManager([fake], clock: { clock.now })
        settings.connect("codex")

        await manager.refresh("codex") // first failure: one minute
        XCTAssertEqual(fake.reads, 1)
        clock.advance(by: 59)
        await manager.refresh("codex")
        XCTAssertEqual(fake.reads, 1)
        clock.advance(by: 2)
        await manager.refresh("codex") // second failure: two minutes
        XCTAssertEqual(fake.reads, 2)
        clock.advance(by: 61)
        await manager.refresh("codex")
        XCTAssertEqual(fake.reads, 2, "the second wait is two minutes")
        clock.advance(by: 60)
        await manager.refresh("codex") // third failure: four minutes
        XCTAssertEqual(fake.reads, 3)

        clock.advance(by: 4 * 60 + 1)
        fake.results = [.failure(.rateLimited(tool: "Codex", retryAfter: clock.now.addingTimeInterval(30 * 60)))]
        await manager.refresh("codex") // fourth failure: eight minutes, but Retry-After says thirty
        XCTAssertEqual(fake.reads, 4)
        clock.advance(by: 20 * 60)
        await manager.refresh("codex")
        XCTAssertEqual(fake.reads, 4, "Retry-After outlasts the exponential wait")
        clock.advance(by: 10 * 60 + 1)
        await manager.refresh("codex")
        XCTAssertEqual(fake.reads, 5)
    }

    // MARK: Stale and error

    @MainActor
    func testTransientFailureKeepsTheLastNumbersAsStale() async throws {
        let fake = FakeProvider(id: "claude", results: [
            .success(Self.snapshot("claude", percent: 42)),
            .failure(.temporarilyUnavailable(tool: "Claude Code")),
        ])
        let (manager, settings) = try makeManager([fake])
        settings.connect("claude")

        await manager.refresh("claude")
        XCTAssertEqual(manager.snapshots["claude"]?.status, .ok)
        await manager.refresh("claude", force: true)
        let stale = try XCTUnwrap(manager.snapshots["claude"])
        XCTAssertEqual(stale.status, .stale)
        XCTAssertEqual(stale.sessionPercent, 42, "the last real reading stays on screen")
        XCTAssertEqual(manager.lastErrors["claude"]?.shortDescription, "Reading sign-in — retrying")
    }

    @MainActor
    func testHardFailureBlanksTheNumbersWithoutBackingOff() async throws {
        let fake = FakeProvider(id: "claude", results: [
            .success(Self.snapshot("claude", percent: 42)),
            .failure(.notSignedIn(tool: "Claude Code")),
            .success(Self.snapshot("claude", percent: 43)),
        ])
        let (manager, settings) = try makeManager([fake])
        settings.connect("claude")

        await manager.refresh("claude")
        await manager.refresh("claude")
        let blank = try XCTUnwrap(manager.snapshots["claude"])
        XCTAssertEqual(blank.status, .error)
        XCTAssertNil(blank.ringPercent, "a sign-in that is gone leaves no numbers behind")
        XCTAssertEqual(manager.lastErrors["claude"]?.shortDescription, "Claude Code not signed in")

        await manager.refresh("claude")
        XCTAssertEqual(fake.reads, 3, "only transient failures back off")
        XCTAssertEqual(manager.snapshots["claude"]?.sessionPercent, 43)
        XCTAssertNil(manager.lastErrors["claude"])
    }

    // MARK: Membership

    @MainActor
    func testRefreshAllReadsConnectedAccountsOrShowsDemo() async throws {
        let claude = FakeProvider(id: "claude", results: [.success(Self.snapshot("claude", percent: 10))])
        let codex = FakeProvider(id: "codex", results: [.success(Self.snapshot("codex", percent: 20))])
        let (manager, settings) = try makeManager([claude, codex])

        await manager.refreshAll()
        XCTAssertEqual(claude.reads + codex.reads, 0, "nothing connected, nothing read")
        XCTAssertEqual(manager.snapshots["claude"]?.status, .demo)
        XCTAssertEqual(manager.snapshots["codex"]?.status, .demo)

        settings.connect("claude")
        await manager.refreshAll()
        XCTAssertEqual(claude.reads, 1)
        XCTAssertEqual(codex.reads, 0, "only connected accounts are read")
        XCTAssertEqual(manager.snapshots["claude"]?.status, .ok)
    }

    @MainActor
    func testConnectIsARealReadAndDropsTheDemoNumbers() async throws {
        let claude = FakeProvider(id: "claude", results: [
            .failure(.notSignedIn(tool: "Claude Code")),
            .success(Self.snapshot("claude", percent: 42)),
        ])
        let codex = FakeProvider(id: "codex")
        let (manager, settings) = try makeManager([claude, codex])
        await manager.refreshAll()
        XCTAssertEqual(manager.snapshots.count, 2)

        do {
            try await manager.connect("claude")
            XCTFail("a first read that fails must not connect the account")
        } catch {
            XCTAssertEqual((error as? ConnectionError)?.shortDescription, "Claude Code not signed in")
        }
        XCTAssertFalse(settings.isConnected("claude"))

        try await manager.connect("claude")
        XCTAssertTrue(settings.isConnected("claude"))
        XCTAssertEqual(manager.snapshots["claude"]?.status, .ok)
        XCTAssertEqual(Array(manager.snapshots.keys), ["claude"], "demo numbers for the others are gone")
    }

    // MARK: Alerts and pace

    @MainActor
    func testNotifierAnnouncesEachThresholdOncePerWindow() {
        let inbox = NotificationInbox()
        let notifier = UsageNotifier(authorize: { $0(true) }, deliver: { inbox.requests.append($0) })
        let resets = Date().addingTimeInterval(3600)
        func consider(_ percent: Double, enabled: Bool = true) {
            notifier.consider(Self.snapshot("claude", percent: percent, resetsAt: resets), enabled: enabled)
        }

        consider(50)
        XCTAssertTrue(inbox.requests.isEmpty)
        consider(76)
        XCTAssertEqual(inbox.requests.count, 1)
        XCTAssertTrue(inbox.bodies[0].hasPrefix("75% of your session used. Resets "), inbox.bodies[0])
        consider(80)
        XCTAssertEqual(inbox.requests.count, 1, "75 is announced once")
        consider(91)
        XCTAssertEqual(inbox.requests.count, 2)
        XCTAssertTrue(inbox.bodies[1].hasPrefix("90%"))
        consider(99)
        XCTAssertEqual(inbox.requests.count, 2)
        consider(3)
        XCTAssertEqual(inbox.requests.count, 3)
        XCTAssertEqual(inbox.requests[2].content.title, "Claude usage reset")
        consider(80)
        XCTAssertEqual(inbox.requests.count, 4, "a fresh window announces 75 again")
        consider(95, enabled: false)
        XCTAssertEqual(inbox.requests.count, 4, "off means off")

        let denied = NotificationInbox()
        let refused = UsageNotifier(authorize: { $0(false) }, deliver: { denied.requests.append($0) })
        refused.consider(Self.snapshot("codex", percent: 95), enabled: true)
        XCTAssertTrue(denied.requests.isEmpty, "nothing is delivered without permission")
    }

    @MainActor
    func testRefreshFeedsTheProjectionAndTheAlerts() async throws {
        let clock = TestClock()
        let inbox = NotificationInbox()
        let fake = FakeProvider(id: "claude", results: [
            .success(Self.snapshot("claude", percent: 10)),
            .success(Self.snapshot("claude", percent: 20)),
            .success(Self.snapshot("claude", percent: 92)),
        ])
        let notifier = UsageNotifier(authorize: { $0(true) }, deliver: { inbox.requests.append($0) })
        let (manager, settings) = try makeManager([fake], notifier: notifier, clock: { clock.now })
        settings.notificationsEnabled = true
        settings.connect("claude")

        await manager.refresh("claude")
        XCTAssertNil(manager.projection(for: "claude"), "one sample says nothing about pace")
        clock.advance(by: 600)
        await manager.refresh("claude")
        let projection = try XCTUnwrap(manager.projection(for: "claude"))
        XCTAssertEqual(projection.ratePerHour, 60, accuracy: 0.001, "10 points in 10 minutes")
        XCTAssertEqual(projection.hitsLimitAt.timeIntervalSince(clock.now), 80.0 / 60 * 3600, accuracy: 1)
        XCTAssertEqual(projection.basis, "session")
        XCTAssertTrue(inbox.requests.isEmpty)

        clock.advance(by: 600)
        await manager.refresh("claude")
        XCTAssertEqual(inbox.bodies, ["90% of your session used."])
    }

    // MARK: Helpers

    /// A manager over `providers` on a throwaway defaults suite, with a
    /// notifier that delivers nowhere unless one is passed in.
    @MainActor
    private func makeManager(
        _ providers: [FakeProvider],
        notifier: UsageNotifier = UsageNotifier(authorize: { $0(true) }, deliver: { _ in }),
        clock: @escaping () -> Date = { Date() }
    ) throws -> (ProviderManager, AppSettings) {
        let suite = "AIrailTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        return (ProviderManager(settings: settings, providers: providers, notifier: notifier, clock: clock), settings)
    }

    /// Lets queued main-actor work run until `condition` holds; fails after two seconds.
    @MainActor
    private func eventually(_ what: String, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(what)")
                return
            }
            await Task.yield()
        }
    }

    private static func snapshot(_ id: String, percent: Double, resetsAt: Date? = nil) -> UsageSnapshot {
        var snapshot = UsageSnapshot.empty(providerId: id, displayName: id.capitalized, status: .ok)
        snapshot.sessionPercent = percent
        snapshot.resetsAt = resetsAt
        return snapshot
    }
}

// MARK: - Test doubles

/// A provider whose reads are scripted: `results` in order, the last one
/// repeating. With `holdsReads` set each read waits for `release()`, and a
/// read whose task was cancelled meanwhile throws like URLSession would.
@MainActor
final class FakeProvider: UsageProviding {
    let id: String
    let displayName: String
    let color = Color.blue
    let symbolName = "circle"
    let connection = ConnectionMethod(toolName: "Fake", summary: "Uses a scripted read", explainer: "A test double.")
    let demoProfile = MockUsageEngine.Profile(plan: "Demo", sessionStart: 20, weeklyLimit: 100, weeklyStart: 30)
    var installed = true

    var results: [Result<UsageSnapshot, ConnectionError>]
    private(set) var reads = 0
    var holdsReads = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(id: String, results: [Result<UsageSnapshot, ConnectionError>] = []) {
        self.id = id
        displayName = id.capitalized
        self.results = results
    }

    func isInstalled() -> Bool { installed }

    func fetchUsage() async throws -> UsageSnapshot {
        let turn = reads
        reads += 1
        if holdsReads {
            await withCheckedContinuation { held.append($0) }
        }
        if Task.isCancelled { throw ConnectionError.network("cancelled") }
        guard !results.isEmpty else { throw ConnectionError.unsupported }
        return try results[min(turn, results.count - 1)].get()
    }

    /// Lets every held read finish.
    func release() {
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }
}

/// A clock the test moves by hand.
@MainActor
final class TestClock {
    private(set) var now = Date(timeIntervalSince1970: 1_800_000_000)

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

/// Where a test's notifier delivers to.
@MainActor
final class NotificationInbox {
    var requests: [UNNotificationRequest] = []
    var bodies: [String] { requests.map(\.content.body) }
}
