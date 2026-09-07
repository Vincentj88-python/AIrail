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
        XCTAssertTrue(manager.refreshingIds.isEmpty, "removed means not refreshing, before the cancelled read lands")

        claude.release()
        await refresh.value
        XCTAssertNil(manager.snapshots["claude"], "a read that lands after its account is removed writes nothing")
        XCTAssertNil(manager.lastErrors["claude"], "nor does the 'cancelled' error it throws")
        XCTAssertTrue(manager.refreshingIds.isEmpty)
    }

    @MainActor
    func testAnAccountAddedBackKeepsItsOwnRefreshingMark() async throws {
        let claude = FakeProvider(id: "claude", results: [.success(Self.snapshot("claude", percent: 42))])
        let codex = FakeProvider(id: "codex", results: [.success(Self.snapshot("codex", percent: 7))])
        let (manager, settings) = try makeManager([claude, codex])
        settings.connect("claude")
        settings.connect("codex")
        claude.holdsReads = true

        let stale = Task { await manager.refresh("claude") }
        await eventually("the read to start") { claude.reads == 1 }
        manager.disconnect("claude")
        settings.connect("claude") // added back while the cancelled read is still out
        let fresh = Task { await manager.refresh("claude") }
        await eventually("the fresh read to start") { claude.reads == 2 }
        XCTAssertTrue(manager.refreshingIds.contains("claude"))

        claude.release(count: 1) // the stale read lands, as "cancelled"
        await stale.value
        XCTAssertTrue(manager.refreshingIds.contains("claude"), "the stale read leaves the fresh read's mark alone")
        claude.release()
        await fresh.value
        XCTAssertEqual(manager.snapshots["claude"]?.sessionPercent, 42, "the fresh read lands")
        XCTAssertTrue(manager.refreshingIds.isEmpty, "and takes its own mark down")
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
        let (manager, settings) = try makeManager([fake], clock: clock)
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

    @MainActor
    func testStaleReadingLosesTheWindowThatHasReset() async throws {
        let clock = TestClock()
        var live = Self.snapshot("claude", percent: 88, resetsAt: clock.now.addingTimeInterval(30))
        live.weeklyPercent = 40
        live.weeklyResetsAt = clock.now.addingTimeInterval(6 * 24 * 3600)
        let fake = FakeProvider(id: "claude", results: [
            .success(live),
            .failure(.temporarilyUnavailable(tool: "Claude Code")),
        ])
        let (manager, settings) = try makeManager([fake], clock: clock)
        settings.connect("claude")

        await manager.refresh("claude")
        clock.advance(by: 10)
        await manager.refresh("claude", force: true) // the read fails: stale, numbers kept
        XCTAssertEqual(manager.snapshots["claude"]?.status, .stale)
        XCTAssertEqual(manager.snapshots["claude"]?.sessionPercent, 88, "the window is still open")

        clock.advance(by: 30) // past the session reset, inside the one-minute backoff
        await manager.refresh("claude") // the timer: no read, but the expired window goes
        XCTAssertEqual(fake.reads, 2)
        let expired = try XCTUnwrap(manager.snapshots["claude"])
        XCTAssertEqual(expired.status, .stale)
        XCTAssertNil(expired.sessionPercent, "a stale 88% past its reset is a known-false number")
        XCTAssertEqual(expired.ringPercent, 40, "the weekly figure is still real")
        XCTAssertEqual(expired.expiredWindowLabel, "session")
        XCTAssertNil(manager.projection(for: "claude"), "the pace belonged to the window that ended")

        clock.advance(by: 60)
        await manager.refresh("claude") // the next failing read re-derives from the last live numbers
        XCTAssertEqual(fake.reads, 3)
        XCTAssertNil(manager.snapshots["claude"]?.sessionPercent, "expiry survives a re-mark from the last live read")
    }

    // MARK: Network and sleep

    @MainActor
    func testOfflineKeepsTheLastNumbersAndReconnectReadsOnce() async throws {
        let clock = TestClock()
        let fake = FakeProvider(id: "claude", results: [.success(Self.snapshot("claude", percent: 42))])
        let (manager, settings) = try makeManager([fake], clock: clock)
        settings.connect("claude")
        await manager.refresh("claude")
        XCTAssertEqual(fake.reads, 1)

        manager.networkDidChange(online: false)
        XCTAssertFalse(manager.isOnline)
        XCTAssertEqual(manager.snapshots["claude"]?.status, .stale)
        XCTAssertEqual(manager.snapshots["claude"]?.sessionPercent, 42, "nothing was tried, so the numbers stay")
        XCTAssertEqual(manager.lastErrors["claude"]?.shortDescription, "Offline")
        await manager.refresh("claude")
        XCTAssertEqual(fake.reads, 1, "no read is attempted without a network path")
        await manager.refresh("claude", force: true)
        XCTAssertEqual(fake.reads, 2, "the Refresh button still insists")

        manager.networkDidChange(online: true)
        await eventually("the back-online read") { fake.reads == 3 }
        XCTAssertEqual(manager.snapshots["claude"]?.status, .ok)
        XCTAssertNil(manager.lastErrors["claude"])

        manager.networkDidChange(online: false)
        XCTAssertEqual(manager.snapshots["claude"]?.status, .stale)
        manager.networkDidChange(online: true)
        await Task.yield()
        XCTAssertEqual(fake.reads, 3, "a path that flaps inside ten seconds doesn't read again")
        XCTAssertEqual(manager.snapshots["claude"]?.status, .ok, "the read from moments ago is reinstated")
        XCTAssertNil(manager.lastErrors["claude"])

        clock.advance(by: 11)
        manager.networkDidChange(online: false)
        manager.networkDidChange(online: true)
        await eventually("the next back-online read") { fake.reads == 4 }
    }

    @MainActor
    func testWakeReadsOnceWhenOnline() async throws {
        let fake = FakeProvider(id: "claude", results: [.success(Self.snapshot("claude", percent: 42))])
        let (manager, settings) = try makeManager([fake])
        settings.connect("claude")
        manager.willSleep()
        await manager.didWake()
        XCTAssertEqual(fake.reads, 1)
        manager.networkDidChange(online: false)
        await manager.didWake()
        XCTAssertEqual(fake.reads, 1, "waking offline waits for the path instead of failing into a backoff")
        XCTAssertEqual(manager.snapshots["claude"]?.status, .stale)
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
    func testNotifierAnnouncesEachThresholdOncePerWindow() async throws {
        let clock = TestClock()
        let inbox = NotificationInbox()
        let notifier = try makeNotifier(inbox, clock: clock)
        var resets = clock.now.addingTimeInterval(3600)
        func consider(_ percent: Double, enabled: Bool = true) async {
            await notifier.consider(Self.snapshot("claude", percent: percent, resetsAt: resets), enabled: enabled)
        }

        await consider(50)
        XCTAssertTrue(inbox.requests.isEmpty)
        await consider(76)
        XCTAssertEqual(inbox.bodies.count, 1)
        XCTAssertTrue(inbox.bodies[0].hasPrefix("75% of your session used. Resets "), inbox.bodies[0])
        let alert = try XCTUnwrap(inbox.alerts.first)
        XCTAssertEqual(alert.identifier, "claude.threshold.75")
        XCTAssertEqual(alert.content.threadIdentifier, "claude", "grouped per account in Notification Center")
        XCTAssertEqual(alert.content.userInfo["providerId"] as? String, "claude", "so a click opens that HUD")
        await consider(80)
        XCTAssertEqual(inbox.bodies.count, 1, "75 is announced once")
        await consider(91)
        XCTAssertEqual(inbox.bodies.count, 2)
        XCTAssertTrue(inbox.bodies[1].hasPrefix("90%"))
        await consider(99)
        XCTAssertEqual(inbox.bodies.count, 2)

        clock.advance(by: 3600)
        resets = clock.now.addingTimeInterval(5 * 3600) // the provider reports the next window
        await consider(3)
        XCTAssertEqual(inbox.bodies.count, 2, "the reset is the system's scheduled alert, not a refresh's guess")
        await consider(80)
        XCTAssertEqual(inbox.bodies.count, 3, "a fresh window announces 75 again")
        await consider(95, enabled: false)
        XCTAssertEqual(inbox.bodies.count, 3, "off means off")
    }

    @MainActor
    func testTheWallAlertNamesTheResetAndFiresOncePerWindow() async throws {
        let clock = TestClock()
        let inbox = NotificationInbox()
        let notifier = try makeNotifier(inbox, clock: clock)
        var resets = clock.now.addingTimeInterval(3600)
        func consider(_ percent: Double) async {
            await notifier.consider(Self.snapshot("claude", percent: percent, resetsAt: resets), enabled: true)
        }

        await consider(80)
        XCTAssertEqual(inbox.bodies.count, 1)
        await consider(100)
        XCTAssertEqual(inbox.bodies.count, 3, "90 and the wall arrive together")
        XCTAssertTrue(inbox.bodies[2].hasPrefix("Limit reached. Resets "), inbox.bodies[2])
        XCTAssertEqual(inbox.alerts.last?.identifier, "claude.wall")
        await consider(100)
        XCTAssertEqual(inbox.bodies.count, 3, "the wall is said once per window")

        clock.advance(by: 3600)
        resets = clock.now.addingTimeInterval(5 * 3600)
        await consider(5)
        XCTAssertEqual(inbox.bodies.count, 3)
        await consider(100)
        XCTAssertEqual(inbox.bodies.count, 5, "a fresh window: 90 and the wall again")
    }

    @MainActor
    func testNotifierRemembersTheWindowAcrossRelaunchAndWaitsForPermission() async throws {
        let clock = TestClock()
        let inbox = NotificationInbox()
        let defaults = try makeDefaults()
        let notifier = try makeNotifier(inbox, clock: clock, defaults: defaults)
        let resets = clock.now.addingTimeInterval(3600)
        func consider(_ id: String, _ percent: Double, on notifier: UsageNotifier) async {
            await notifier.consider(Self.snapshot(id, percent: percent, resetsAt: id == "codex" ? resets : nil), enabled: true)
        }

        inbox.authorized = false
        await consider("codex", 80, on: notifier)
        XCTAssertTrue(inbox.requests.isEmpty, "nothing is delivered without permission")
        inbox.authorized = true
        await consider("codex", 80, on: notifier)
        XCTAssertEqual(inbox.bodies.count, 1, "an alert macOS wasn't yet allowed to show comes through once it is")

        let relaunched = try makeNotifier(inbox, clock: clock, defaults: defaults)
        await consider("codex", 82, on: relaunched)
        XCTAssertEqual(inbox.bodies.count, 1, "a relaunch in the same window doesn't say 75 again")
        await consider("codex", 91, on: relaunched)
        XCTAssertEqual(inbox.bodies.count, 2)

        // A meter with no reset time only starts over once it's well under
        // what was announced — a raised key limit, not a wobble.
        await consider("openrouter", 78, on: relaunched)
        XCTAssertEqual(inbox.bodies.count, 3)
        await consider("openrouter", 60, on: relaunched)
        await consider("openrouter", 78, on: relaunched)
        XCTAssertEqual(inbox.bodies.count, 3, "a dip to 60 isn't a reset")
        await consider("openrouter", 20, on: relaunched)
        await consider("openrouter", 78, on: relaunched)
        XCTAssertEqual(inbox.bodies.count, 4)
    }

    @MainActor
    func testNotifierKeepsAMarkPerWindowWhenTheRingSwapsSources() async throws {
        let clock = TestClock()
        let inbox = NotificationInbox()
        let defaults = try makeDefaults()
        let notifier = try makeNotifier(inbox, clock: clock, defaults: defaults)
        let session = clock.now.addingTimeInterval(3600)
        let week = clock.now.addingTimeInterval(5 * 24 * 3600)
        // Codex: the 5-hour window when the plan reports one, else the weekly
        // meter — the ring, and so the alert, swaps sources between reads.
        func consider(session percent: Double) async {
            await notifier.consider(Self.snapshot("codex", percent: percent, resetsAt: session), enabled: true)
        }
        func consider(weekly percent: Double) async {
            var snapshot = UsageSnapshot.empty(providerId: "codex", displayName: "Codex", status: .ok)
            snapshot.weeklyPercent = percent
            snapshot.weeklyResetsAt = week
            await notifier.consider(snapshot, enabled: true)
        }
        func marks() -> [String: Int] {
            defaults.dictionary(forKey: "announcedThresholds") as? [String: Int] ?? [:]
        }

        await consider(session: 80)
        XCTAssertEqual(inbox.bodies.count, 1)
        await consider(weekly: 80)
        XCTAssertEqual(inbox.bodies.count, 2, "the weekly window is another window, announced on its own")
        XCTAssertTrue(inbox.bodies[1].hasPrefix("75% of your weekly used."), inbox.bodies[1])
        await consider(session: 82)
        XCTAssertEqual(inbox.bodies.count, 2, "back on the session window, 75 was already said there")
        await consider(weekly: 91)
        XCTAssertEqual(inbox.bodies.count, 3)
        await consider(session: 91)
        XCTAssertEqual(inbox.bodies.count, 4, "each window climbs its own thresholds")
        let sessionMark = "codex.\(Int(session.timeIntervalSince1970))"
        let weekMark = "codex.\(Int(week.timeIntervalSince1970))"
        XCTAssertEqual(marks(), [sessionMark: 90, weekMark: 90])

        // The session window passes: its mark goes with the next write, the
        // weekly one (still ahead) stays.
        clock.advance(by: 3601)
        let next = clock.now.addingTimeInterval(3600)
        await notifier.consider(Self.snapshot("codex", percent: 76, resetsAt: next), enabled: true)
        XCTAssertEqual(inbox.bodies.count, 5, "a fresh session window announces 75 again")
        XCTAssertEqual(marks(), ["codex.\(Int(next.timeIntervalSince1970))": 75, weekMark: 90])

        notifier.forget("codex")
        XCTAssertTrue(marks().isEmpty, "a removed account leaves no mark in any window")
    }

    @MainActor
    func testNotifierSchedulesTheResetAtTheReportedTimeAndTakesItBack() async throws {
        let clock = TestClock()
        let inbox = NotificationInbox()
        let notifier = try makeNotifier(inbox, clock: clock)
        let resets = clock.now.addingTimeInterval(90 * 60)
        func consider(_ id: String, _ percent: Double, resetsAt: Date? = resets) async {
            await notifier.consider(Self.snapshot(id, percent: percent, resetsAt: resetsAt), enabled: true)
        }

        await consider("claude", 60)
        XCTAssertTrue(inbox.scheduled.isEmpty, "nothing to wait for until a threshold is passed")
        await consider("claude", 76)
        let reset = try XCTUnwrap(inbox.scheduled.first)
        XCTAssertEqual(reset.identifier, "claude.reset")
        XCTAssertEqual(reset.content.title, "Claude usage reset")
        XCTAssertEqual(reset.content.threadIdentifier, "claude")
        let trigger = try XCTUnwrap(reset.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(trigger.timeInterval, 90 * 60, accuracy: 1, "at the time the provider reported, not on the next refresh")
        XCTAssertFalse(trigger.repeats)
        await consider("claude", 92)
        XCTAssertEqual(inbox.scheduled.count, 1, "90% doesn't schedule it twice")

        notifier.forget("claude")
        XCTAssertEqual(inbox.withdrawn, ["claude.reset"], "a removed account's pending alert goes with it")
        await consider("claude", 92)
        XCTAssertEqual(inbox.scheduled.count, 2, "connected again, it's watched again")
        notifier.withdrawResets(for: ["claude", "codex"])
        XCTAssertEqual(inbox.withdrawn, ["claude.reset", "claude.reset", "codex.reset"])

        await consider("codex", 80, resetsAt: clock.now.addingTimeInterval(-60))
        XCTAssertEqual(inbox.bodies.count, 4, "the threshold is still announced")
        XCTAssertEqual(inbox.scheduled.count, 2, "but a reset time already past isn't scheduled")
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
        let (manager, settings) = try makeManager([fake], inbox: inbox, clock: clock)
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

    @MainActor
    func testNewWindowRestartsThePaceAndOffTakesBackTheReset() async throws {
        let clock = TestClock()
        let inbox = NotificationInbox()
        let window = clock.now.addingTimeInterval(2 * 3600)
        let next = window.addingTimeInterval(5 * 3600)
        let fake = FakeProvider(id: "claude", results: [
            .success(Self.snapshot("claude", percent: 70, resetsAt: window)),
            .success(Self.snapshot("claude", percent: 80, resetsAt: window)),
            .success(Self.snapshot("claude", percent: 5, resetsAt: next)),
            .success(Self.snapshot("claude", percent: 6, resetsAt: next)),
        ])
        let (manager, settings) = try makeManager([fake], inbox: inbox, clock: clock)
        settings.notificationsEnabled = true
        settings.connect("claude")

        await manager.refresh("claude")
        clock.advance(by: 600)
        await manager.refresh("claude")
        XCTAssertEqual(try XCTUnwrap(manager.projection(for: "claude")).ratePerHour, 60, accuracy: 0.001)
        XCTAssertEqual(inbox.bodies.count, 1)
        XCTAssertEqual(inbox.scheduled.map(\.identifier), ["claude.reset"], "past 75, the reset is scheduled")

        clock.advance(by: 2 * 3600)
        await manager.refresh("claude") // the window rolled: a new reset time
        clock.advance(by: 600)
        await manager.refresh("claude")
        let projection = try XCTUnwrap(manager.projection(for: "claude"))
        XCTAssertEqual(projection.ratePerHour, 6, accuracy: 0.001, "the pace is measured inside the new window only")

        settings.notificationsEnabled = false
        XCTAssertEqual(inbox.withdrawn, ["claude.reset"], "off takes back what the system was holding")
        manager.stop()
        XCTAssertEqual(inbox.withdrawn, ["claude.reset", "claude.reset"], "so does quitting")
    }

    // MARK: Helpers

    /// A manager over `providers` on a throwaway defaults suite, with a
    /// notifier delivering to `inbox` (nowhere anyone looks, by default).
    @MainActor
    private func makeManager(
        _ providers: [FakeProvider],
        inbox: NotificationInbox = NotificationInbox(),
        clock: TestClock = TestClock()
    ) throws -> (ProviderManager, AppSettings) {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        let notifier = try makeNotifier(inbox, clock: clock, defaults: defaults)
        return (ProviderManager(settings: settings, providers: providers, notifier: notifier, clock: { clock.now }), settings)
    }

    /// A notifier whose system side is `inbox`, on its own throwaway
    /// defaults unless a suite is shared to play a relaunch.
    @MainActor
    private func makeNotifier(_ inbox: NotificationInbox, clock: TestClock, defaults: UserDefaults? = nil) throws -> UsageNotifier {
        UsageNotifier(
            defaults: try defaults ?? makeDefaults(),
            now: { clock.now },
            authorization: { inbox.authorized },
            deliver: { inbox.requests.append($0) },
            withdraw: { inbox.withdrawn += $0 }
        )
    }

    /// A defaults suite of its own, removed at teardown.
    @MainActor
    private func makeDefaults() throws -> UserDefaults {
        let suite = "AIrailTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
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

    /// Lets every held read finish — or only the first `count` of them.
    func release(count: Int = .max) {
        let waiting = Array(held.prefix(count))
        held.removeFirst(waiting.count)
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

/// The system's side of notifications, for tests: whether AIrail may post,
/// what it handed over and what it took back.
@MainActor
final class NotificationInbox {
    var authorized = true
    var requests: [UNNotificationRequest] = []
    var withdrawn: [String] = []
    /// Shown now (no trigger).
    var alerts: [UNNotificationRequest] { requests.filter { $0.trigger == nil } }
    /// Left with the system to fire later (the reset alert).
    var scheduled: [UNNotificationRequest] { requests.filter { $0.trigger != nil } }
    var bodies: [String] { alerts.map(\.content.body) }
}
