import Combine
import Foundation
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

    private let settings: AppSettings
    private var demoEngines: [String: MockUsageEngine] = [:]
    private var lastLive: [String: UsageSnapshot] = [:]
    /// Recent (time, ring percent) samples per provider, for the burn-rate projection.
    private var percentHistory: [String: [(date: Date, percent: Double)]] = [:]
    private let notifier = UsageNotifier()
    /// Earliest time each provider may be fetched again; set when a read is
    /// rate-limited or fails, so the timer doesn't keep hammering an endpoint.
    private var backoffUntil: [String: Date] = [:]
    /// Consecutive failures per provider, for exponential backoff.
    private var failureStreak: [String: Int] = [:]
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init(settings: AppSettings) {
        self.settings = settings
        let providers = Self.makeProviders()
        self.providers = providers
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
        lastLive[providerId] = snapshot
        snapshots[providerId] = snapshot
        lastErrors[providerId] = nil
        backoffUntil[providerId] = nil
        failureStreak[providerId] = nil
        if wasDemo {
            // Demo numbers for the other providers are no longer shown anywhere.
            snapshots = snapshots.filter { settings.isConnected($0.key) }
        }
    }

    func disconnect(_ providerId: String) {
        (provider(for: providerId) as? any KeyedUsageProviding)?.forgetKey()
        settings.disconnect(providerId)
        snapshots[providerId] = nil
        lastLive[providerId] = nil
        lastErrors[providerId] = nil
        backoffUntil[providerId] = nil
        failureStreak[providerId] = nil
        percentHistory[providerId] = nil
        notifier.forget(providerId)
        if isShowingDemo {
            Task { await refreshAll() }
        }
    }

    // MARK: Refresh

    func start() {
        Task { await refreshAll() }
        restartTimer(interval: settings.refreshInterval)
    }

    /// Providers refresh concurrently so one slow endpoint can't hold up the rest.
    func refreshAll() async {
        let tasks = providers.map(\.id).map { id in
            Task { @MainActor in await self.refresh(id) }
        }
        for task in tasks {
            await task.value
        }
    }

    /// A manual refresh (the account page's Refresh button) ignores the
    /// backoff window; the timer honours it.
    func refresh(_ providerId: String, force: Bool = false) async {
        guard let provider = provider(for: providerId) else { return }
        if settings.isConnected(providerId) {
            if !force, let until = backoffUntil[providerId], until > Date() {
                return // still cooling down; leave the last snapshot in place
            }
            refreshingIds.insert(providerId)
            defer { refreshingIds.remove(providerId) }
            do {
                let snapshot = try await provider.fetchUsage()
                lastLive[providerId] = snapshot
                snapshots[providerId] = snapshot
                lastErrors[providerId] = nil
                backoffUntil[providerId] = nil
                failureStreak[providerId] = nil
                recordSample(snapshot)
                notifier.consider(snapshot, enabled: settings.notificationsEnabled)
            } catch {
                let failure = (error as? ConnectionError) ?? .unreadable(error.localizedDescription)
                lastErrors[providerId] = failure
                applyBackoff(providerId, failure: failure)
                // Keep the last real reading on screen when the failure is
                // just "couldn't refresh"; blank it when the sign-in is gone.
                if failure.isTransient, let previous = lastLive[providerId] {
                    snapshots[providerId] = previous.marking(.stale)
                } else {
                    snapshots[providerId] = .empty(
                        providerId: providerId, displayName: provider.displayName, status: .error
                    )
                }
            }
        } else if isShowingDemo {
            snapshots[providerId] = demoEngines[providerId]?.snapshot(
                providerId: providerId, displayName: provider.displayName
            )
        }
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
        var until = Date().addingTimeInterval(exponential)
        if case .rateLimited(_, let retryAfter) = failure, let retryAfter {
            until = max(until, retryAfter)
        }
        backoffUntil[providerId] = until
    }

    private func recordSample(_ snapshot: UsageSnapshot) {
        guard let percent = snapshot.ringPercent else { return }
        var samples = percentHistory[snapshot.providerId] ?? []
        samples.append((Date(), percent))
        let cutoff = Date().addingTimeInterval(-1800) // keep the last 30 minutes
        samples.removeAll { $0.date < cutoff }
        percentHistory[snapshot.providerId] = samples
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
        let hitsAt = Date().addingTimeInterval((100 - percent) / slope * 3600)
        let reset = snapshot.sessionPercent != nil ? snapshot.resetsAt : (snapshot.weeklyResetsAt ?? snapshot.resetsAt)
        let resetsFirst = reset.map { $0 < hitsAt } ?? false
        return UsageProjection(
            ratePerHour: slope,
            hitsLimitAt: hitsAt,
            resetsFirst: resetsFirst,
            basis: snapshot.sessionPercent != nil ? "session" : snapshot.periodLabel
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
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
