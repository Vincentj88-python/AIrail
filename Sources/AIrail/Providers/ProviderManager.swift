import Combine
import Foundation
import Network
import SwiftUI

/// Value-type description of a provider, safe to hand to SwiftUI lists.
struct ProviderInfo: Identifiable, Sendable {
    let id: String
    let displayName: String
    let color: Color
    let symbolName: String
    let brandIconPath: String?
    let installed: Bool
    let connection: ConnectionMethod
    let kind: ProviderKind
}

@MainActor
final class ProviderManager: ObservableObject {
    let providers: [any UsageProviding]
    let allProviderInfos: [ProviderInfo]

    @Published private(set) var snapshots: [String: UsageSnapshot] = [:]
    /// Why the latest read of a connected account failed, by provider id.
    @Published private(set) var lastErrors: [String: ConnectionError] = [:]
    @Published private(set) var refreshingIds: Set<String> = []
    /// Whether the Mac has a network path. Without one, reads aren't tried:
    /// every account keeps its last numbers as stale under an "offline" note.
    @Published private(set) var isOnline = true
    /// The "used elsewhere" observation per account, when the session figure
    /// moved while this Mac's tool wrote nothing.
    @Published private(set) var elsewhere: [String: UsageElsewhere] = [:]
    private var elsewhereWatches: [String: UsageElsewhere.Watch] = [:]

    private let settings: AppSettings
    private let notifier: UsageNotifier
    /// What each account keeps on disk between launches; nil in tests that don't care.
    private let store: UsageStore?
    private var ledgers: [String: UsageLedger] = [:]
    /// The wall clock, so tests can move time instead of waiting out a backoff.
    private let clock: () -> Date
    private var demoEngines: [String: MockUsageEngine] = [:]
    private var lastLive: [String: UsageSnapshot] = [:]
    /// Recent (time, ring percent) samples per provider, for the burn-rate projection.
    private var percentHistory: [String: [(date: Date, percent: Double)]] = [:]
    /// The window (its reset time) those samples belong to; a new window starts them over.
    private var sampleWindows: [String: Date] = [:]
    /// The read in progress per provider. A second refresh joins it instead
    /// of starting another; disconnecting cancels it.
    private var inflight: [String: Task<Void, Never>] = [:]
    /// Earliest time each provider may be fetched again; set when a read is
    /// rate-limited or fails, so the timer doesn't keep hammering an endpoint.
    private var backoffUntil: [String: Date] = [:]
    /// Consecutive failures per provider, for exponential backoff.
    private var failureStreak: [String: Int] = [:]
    private var timer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var wakeTask: Task<Void, Never>?
    /// When the last back-online read ran, so a flapping path reads once.
    private var lastReconnectRefresh: Date?
    private var cancellables: Set<AnyCancellable> = []

    /// The app passes only `settings`; tests hand in scripted providers, a
    /// notifier that delivers nowhere and a clock they can move.
    init(
        settings: AppSettings,
        providers: [any UsageProviding] = ProviderManager.makeProviders(),
        notifier: UsageNotifier = UsageNotifier(),
        clock: @escaping () -> Date = { Date() },
        store: UsageStore? = UsageStore()
    ) {
        self.settings = settings
        self.providers = providers
        self.notifier = notifier
        self.clock = clock
        self.store = store
        allProviderInfos = providers.map {
            ProviderInfo(
                id: $0.id,
                displayName: $0.displayName,
                color: $0.color,
                symbolName: $0.symbolName,
                brandIconPath: $0.brandIconPath,
                installed: $0.isInstalled(),
                connection: $0.connection,
                kind: $0.kind
            )
        }
        for provider in providers {
            demoEngines[provider.id] = MockUsageEngine(profile: provider.demoProfile)
        }

        settings.$refreshInterval
            .dropFirst()
            .sink { [weak self] interval in
                self?.restartTimer(interval: interval)
            }
            .store(in: &cancellables)
        // Off means off: a reset alert already handed to the system would
        // otherwise still fire at the reset time.
        settings.$notificationsEnabled
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in
                guard let self else { return }
                self.notifier.withdrawResets(for: self.providers.map(\.id))
            }
            .store(in: &cancellables)
    }

    static func makeProviders() -> [any UsageProviding] {
        let tools: [any UsageProviding] = [
            CursorProvider(),
            ClaudeProvider(),
            CodexProvider(),
            GeminiProvider(),
            CopilotProvider(),
        ]
        return tools + KeyedPlatform.catalog.map { KeyedProvider(platform: $0) }
    }

    // MARK: Membership

    /// True until the first account is connected: the rail then shows demo
    /// data for the tools found on this Mac so it isn't empty.
    var isShowingDemo: Bool {
        !settings.hasConnectedAccounts
    }

    /// What the rail displays: connected accounts the user hasn't hidden, or
    /// the demo set while nothing is connected.
    var railProviderInfos: [ProviderInfo] {
        if isShowingDemo { return demoProviderInfos }
        return allProviderInfos.filter { settings.isShownOnRail($0.id) }
    }

    /// Demo data only ever stands in for tools that could be on this Mac.
    var demoProviderInfos: [ProviderInfo] {
        let tools = allProviderInfos.filter { $0.kind == .tool }
        let detected = tools.filter(\.installed)
        return detected.isEmpty ? tools : detected
    }

    var connectedProviderInfos: [ProviderInfo] {
        allProviderInfos.filter { settings.isConnected($0.id) }
    }

    /// Tools offered as tiles in the Add Account sheet.
    var connectableProviderInfos: [ProviderInfo] {
        allProviderInfos.filter { $0.kind == .tool && !settings.isConnected($0.id) }
    }

    /// Platforms offered behind the sheet's "Other…" tile.
    var connectablePlatformInfos: [ProviderInfo] {
        allProviderInfos.filter { $0.kind == .apiKey && !settings.isConnected($0.id) }
    }

    /// The reading the collapsed rail and island show: nearest limit, room, next reset.
    var railHeadroom: HeadroomSummary {
        HeadroomSummary.of(railProviderInfos.map { ($0.id, $0.displayName, snapshots[$0.id]) })
    }

    func providerInfo(for id: String) -> ProviderInfo? {
        allProviderInfos.first { $0.id == id }
    }

    func snapshot(for id: String) -> UsageSnapshot? {
        snapshots[id]
    }

    private func provider(for id: String) -> (any UsageProviding)? {
        providers.first { $0.id == id }
    }

    // MARK: Accounts

    /// Connecting is a real read: the account joins the list only once its
    /// sign-in (or pasted key) has been used successfully. A key that fails
    /// its first read is not kept.
    func connect(_ providerId: String, key: String? = nil) async throws {
        guard let provider = provider(for: providerId) else { return }
        refreshingIds.insert(providerId)
        defer { refreshingIds.remove(providerId) }
        let keyed = provider as? any KeyedUsageProviding
        if let keyed, let key {
            try keyed.storeKey(key)
        }
        let snapshot: UsageSnapshot
        do {
            snapshot = try await provider.fetchUsage()
        } catch {
            if key != nil { keyed?.forgetKey() }
            throw error
        }
        let wasDemo = isShowingDemo
        settings.connect(providerId)
        let published = recorded(snapshot)
        lastLive[providerId] = published
        snapshots[providerId] = published
        lastErrors[providerId] = nil
        backoffUntil[providerId] = nil
        failureStreak[providerId] = nil
        if wasDemo {
            // Demo numbers for the other providers are no longer shown anywhere.
            snapshots = snapshots.filter { settings.isConnected($0.key) }
        }
    }

    func disconnect(_ providerId: String) {
        // A read still in flight must not put the numbers back when it lands.
        inflight[providerId]?.cancel()
        inflight[providerId] = nil
        refreshingIds.remove(providerId) // the cancelled read leaves the mark to whoever holds it next
        (provider(for: providerId) as? any KeyedUsageProviding)?.forgetKey()
        settings.disconnect(providerId)
        snapshots[providerId] = nil
        lastLive[providerId] = nil
        lastErrors[providerId] = nil
        backoffUntil[providerId] = nil
        failureStreak[providerId] = nil
        percentHistory[providerId] = nil
        sampleWindows[providerId] = nil
        elsewhere[providerId] = nil
        elsewhereWatches[providerId] = nil
        ledgers[providerId] = nil
        if let store { Task { await store.delete(providerId) } }
        notifier.forget(providerId)
        if isShowingDemo {
            Task { await refreshAll() }
        }
    }

    // MARK: Refresh

    func start() {
        Task {
            await restore()
            await refreshAll()
        }
        restartTimer(interval: settings.refreshInterval)
        watchNetworkAndSleep()
    }

    /// What the ledgers kept: each connected account's last real numbers
    /// come back as stale (so a first read that fails leaves numbers, not a
    /// blank), and its pace samples come back so the first fresh read is a
    /// pace rather than a two-minute wait.
    func restore() async {
        guard let store else { return }
        for info in connectedProviderInfos {
            guard let ledger = await store.load(info.id) else { continue }
            ledgers[info.id] = ledger
            if let saved = ledger.lastSnapshot, snapshots[info.id] == nil {
                lastLive[info.id] = saved
                snapshots[info.id] = expiring(saved.marking(.stale), for: info.id)
            }
            if !ledger.percentSamples.isEmpty {
                percentHistory[info.id] = ledger.percentSamples.map { ($0.date, $0.percent) }
                sampleWindows[info.id] = ledger.sampleWindow
            }
        }
    }

    /// Quitting: the timer stops, and any reset alert handed to the system
    /// is taken back so nothing fires for an app that isn't running.
    func stop() {
        timer?.invalidate()
        timer = nil
        wakeTask?.cancel()
        pathMonitor?.cancel()
        pathMonitor = nil
        notifier.withdrawResets(for: providers.map(\.id))
    }

    // MARK: Network and sleep

    /// The network path and the Mac's sleep state, observed only from
    /// `start()` so tests drive the same entry points by hand. The path
    /// monitor is local kernel state; nothing leaves the Mac to ask it.
    private func watchNetworkAndSleep() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.networkDidChange(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "com.codeandvin.airail.network"))
        pathMonitor = monitor

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.willSleep() }
            .store(in: &cancellables)
        workspace.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // didWake arrives before Wi-Fi has re-associated; give it a moment.
                wakeTask?.cancel()
                wakeTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    await self?.didWake()
                }
            }
            .store(in: &cancellables)
    }

    /// Sleep: the timer stops, so nothing fires into a network that is going
    /// away (an overdue timer firing at wake was the source of the wake-time
    /// failure and its one-minute backoff).
    func willSleep() {
        timer?.invalidate()
        timer = nil
    }

    /// Wake: the timer restarts and one read runs, if there is a path to run it on.
    func didWake() async {
        restartTimer(interval: settings.refreshInterval)
        if isOnline { await refreshAll() }
    }

    /// Offline: every connected account keeps its last numbers as stale under
    /// an "offline" note, with no backoff, since nothing was tried. Back
    /// online: the backoffs earned by the outage are cleared and one read
    /// runs; a path that flaps inside ten seconds reinstates the read from
    /// moments ago instead of reading again.
    func networkDidChange(online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        let ids = connectedProviderInfos.map(\.id)
        guard online else {
            for id in ids { markOffline(id) }
            return
        }
        let now = clock()
        let recentlyRefreshed = lastReconnectRefresh.map { now.timeIntervalSince($0) < 10 } ?? false
        for id in ids {
            guard let error = lastErrors[id], error.isNetworkOutage else { continue }
            backoffUntil[id] = nil
            failureStreak[id] = nil
            if recentlyRefreshed, case .offline = error, let live = lastLive[id] {
                lastErrors[id] = nil
                snapshots[id] = live
            }
        }
        guard !recentlyRefreshed else { return }
        lastReconnectRefresh = now
        Task { await refreshAll() }
    }

    private func markOffline(_ providerId: String) {
        lastErrors[providerId] = .offline
        if let previous = lastLive[providerId] {
            snapshots[providerId] = expiring(previous.marking(.stale), for: providerId)
        }
    }

    /// Every connected account (or the demo set while nothing is connected)
    /// refreshes concurrently, so one slow endpoint can't hold up the rest.
    func refreshAll() async {
        let ids = (isShowingDemo ? demoProviderInfos : connectedProviderInfos).map(\.id)
        let tasks = ids.map { id in
            Task { @MainActor in await self.refresh(id) }
        }
        for task in tasks {
            await task.value
        }
    }

    /// One read per provider at a time: a refresh that finds one in flight
    /// waits for its result rather than starting (or cancelling) another.
    /// A manual refresh (the account page's Refresh button) ignores the
    /// backoff window; the timer honours it.
    func refresh(_ providerId: String, force: Bool = false) async {
        if let running = inflight[providerId] {
            await running.value
            return
        }
        guard let provider = provider(for: providerId) else { return }
        if settings.isConnected(providerId) {
            guard isOnline || force else {
                markOffline(providerId) // nothing to try; the Refresh button may still insist
                return
            }
            if !force, let until = backoffUntil[providerId], until > clock() {
                // Still cooling down: the last snapshot stays, minus any
                // window that has reset in the meantime.
                if let current = snapshots[providerId], current.status == .stale {
                    let expired = expiring(current, for: providerId)
                    if expired != current { snapshots[providerId] = expired }
                }
                return
            }
            let task = Task { @MainActor in await self.read(provider) }
            inflight[providerId] = task
            await task.value
            if inflight[providerId] == task {
                inflight[providerId] = nil
            }
        } else if isShowingDemo {
            snapshots[providerId] = demoEngines[providerId]?.snapshot(
                providerId: providerId, displayName: provider.displayName
            )
        }
    }

    /// The read behind `refresh`, run as its own task so a second refresh can
    /// join it and a disconnect can cancel it. Nothing is written once the
    /// account is gone — not even the "cancelled" error the read then throws.
    private func read(_ provider: any UsageProviding) async {
        let providerId = provider.id
        refreshingIds.insert(providerId)
        // A cancelled read was unmarked by `disconnect`; if the account was
        // added back meanwhile, the mark belongs to its fresh read.
        defer { if !Task.isCancelled { refreshingIds.remove(providerId) } }
        do {
            let snapshot = try await provider.fetchUsage()
            guard stillWanted(providerId) else { return }
            recordSample(snapshot)
            let published = recorded(snapshot)
            lastLive[providerId] = published
            snapshots[providerId] = published
            lastErrors[providerId] = nil
            backoffUntil[providerId] = nil
            failureStreak[providerId] = nil
            noteElsewhere(published)
            await notifier.consider(published, enabled: settings.notificationsEnabled)
        } catch {
            guard stillWanted(providerId) else { return }
            let failure = (error as? ConnectionError) ?? .unreadable(error.localizedDescription)
            lastErrors[providerId] = failure
            applyBackoff(providerId, failure: failure)
            // Keep the last real reading on screen when the failure is
            // just "couldn't refresh"; blank it when the sign-in is gone.
            if failure.isTransient, let previous = lastLive[providerId] {
                snapshots[providerId] = expiring(previous.marking(.stale), for: providerId)
            } else {
                snapshots[providerId] = .empty(
                    providerId: providerId, displayName: provider.displayName, status: .error
                )
            }
        }
    }

    /// Drops the stale numbers of any window that has reset since they were
    /// read. The first time a window expires, the alerts and pace samples
    /// that belonged to it go too, so a fresh read starts from nothing.
    private func expiring(_ snapshot: UsageSnapshot, for providerId: String) -> UsageSnapshot {
        let expired = snapshot.expiringWindows(now: clock())
        if let reset = expired.expiredResetAt, reset != snapshots[providerId]?.expiredResetAt {
            notifier.forget(providerId)
            percentHistory[providerId] = nil
            sampleWindows[providerId] = nil
        }
        return expired
    }

    /// False once the read's task was cancelled or its account removed.
    private func stillWanted(_ providerId: String) -> Bool {
        !Task.isCancelled && settings.isConnected(providerId)
    }

    /// Backs off after a transient failure: honour the server's Retry-After if
    /// it sent one, else grow the wait 1→2→4… minutes (capped), so we stop
    /// hammering an endpoint that's already pushing back.
    private func applyBackoff(_ providerId: String, failure: ConnectionError) {
        guard failure.isTransient else {
            backoffUntil[providerId] = nil
            failureStreak[providerId] = nil
            return
        }
        let streak = (failureStreak[providerId] ?? 0) + 1
        failureStreak[providerId] = streak
        let capped = min(streak, 5)
        let exponential = pow(2.0, Double(capped - 1)) * 60 // 1, 2, 4, 8, 16 min
        var until = clock().addingTimeInterval(exponential)
        if case .rateLimited(_, let retryAfter) = failure, let retryAfter {
            until = max(until, retryAfter)
        }
        backoffUntil[providerId] = until
    }

    /// Folds a successful read into the account's ledger and hands back what
    /// to publish: the read itself, or — for an account with no per-request
    /// feed (Copilot) — the read with a daily chart derived from the levels
    /// the ledger has sampled. The write happens off the main actor.
    private func recorded(_ snapshot: UsageSnapshot) -> UsageSnapshot {
        let id = snapshot.providerId
        let now = clock()
        var ledger = ledgers[id] ?? UsageLedger()
        var published = snapshot
        if snapshot.detail.days.isEmpty, snapshot.weeklyUsed != nil {
            ledger.recordLevel(snapshot, now: now)
            let days = ledger.derivedDays(count: 7, now: now)
            if !days.isEmpty {
                published.detail.days = days
                published.detail.week = days.reduce(into: UsageAggregate()) { $0.merge($1.usage) }
            }
        }
        let samples = (percentHistory[id] ?? []).map { PercentSample(date: $0.date, percent: $0.percent) }
        ledger.record(published, samples: samples, window: sampleWindows[id], now: now)
        ledgers[id] = ledger
        if let store {
            let copy = ledger
            Task { try? await store.save(copy, for: id) }
        }
        return published
    }

    private func noteElsewhere(_ snapshot: UsageSnapshot) {
        let id = snapshot.providerId
        var watch = elsewhereWatches[id]
        let note = UsageElsewhere.evaluate(snapshot, watch: &watch, now: clock())
        elsewhereWatches[id] = watch
        if elsewhere[id] != note { elsewhere[id] = note }
    }

    private func recordSample(_ snapshot: UsageSnapshot) {
        guard let percent = snapshot.ringPercent else { return }
        let now = clock()
        let id = snapshot.providerId
        // A slope across a window reset means nothing: a new reset time
        // starts the pace from scratch.
        var samples = sampleWindows[id] == snapshot.ringResetsAt ? percentHistory[id] ?? [] : []
        sampleWindows[id] = snapshot.ringResetsAt
        samples.append((now, percent))
        let cutoff = now.addingTimeInterval(-1800) // keep the last 30 minutes
        samples.removeAll { $0.date < cutoff }
        percentHistory[id] = samples
    }

    /// When the connected account would hit its limit at the pace it's been
    /// climbing this session — nil if it isn't meaningfully climbing.
    func projection(for id: String) -> UsageProjection? {
        guard let snapshot = snapshots[id], snapshot.status == .ok,
              let percent = snapshot.ringPercent, percent < 100,
              let samples = percentHistory[id], samples.count >= 2,
              let first = samples.first, let last = samples.last,
              last.date.timeIntervalSince(first.date) >= 120 // need a couple of minutes
        else { return nil }
        let hours = last.date.timeIntervalSince(first.date) / 3600
        let slope = (last.percent - first.percent) / hours // %/hour
        guard slope >= 1 else { return nil } // essentially flat → no useful projection
        let hitsAt = clock().addingTimeInterval((100 - percent) / slope * 3600)
        let resetsFirst = snapshot.ringResetsAt.map { $0 < hitsAt } ?? false
        return UsageProjection(
            ratePerHour: slope,
            hitsLimitAt: hitsAt,
            resetsFirst: resetsFirst,
            basis: snapshot.ringWindowLabel
        )
    }

    private func restartTimer(interval: Double) {
        timer?.invalidate()
        // Timer on the main run loop's .common mode; it simply doesn't fire
        // while the Mac sleeps, which is the pause behavior we want.
        let timer = Timer(timeInterval: max(10, interval), repeats: true) { _ in
            Task { @MainActor [weak self] in
                await self?.refreshAll()
            }
        }
        timer.tolerance = max(5, interval * 0.1) // lets the system coalesce wake-ups
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
