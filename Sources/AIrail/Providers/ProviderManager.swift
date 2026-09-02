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
                connection: $0.connection
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
        [
            CursorProvider(),
            ClaudeProvider(),
            CodexProvider(),
            GeminiProvider(),
            CopilotProvider(),
        ]
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

    var demoProviderInfos: [ProviderInfo] {
        let detected = allProviderInfos.filter(\.installed)
        return detected.isEmpty ? allProviderInfos : detected
    }

    var connectedProviderInfos: [ProviderInfo] {
        allProviderInfos.filter { settings.isConnected($0.id) }
    }

    var connectableProviderInfos: [ProviderInfo] {
        allProviderInfos.filter { !settings.isConnected($0.id) }
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
    /// sign-in has been found and used successfully.
    func connect(_ providerId: String) async throws {
        guard let provider = provider(for: providerId) else { return }
        refreshingIds.insert(providerId)
        defer { refreshingIds.remove(providerId) }
        let snapshot = try await provider.fetchUsage()
        let wasDemo = isShowingDemo
        settings.connect(providerId)
        lastLive[providerId] = snapshot
        snapshots[providerId] = snapshot
        lastErrors[providerId] = nil
        if wasDemo {
            // Demo numbers for the other providers are no longer shown anywhere.
            snapshots = snapshots.filter { settings.isConnected($0.key) }
        }
    }

    func disconnect(_ providerId: String) {
        settings.disconnect(providerId)
        snapshots[providerId] = nil
        lastLive[providerId] = nil
        lastErrors[providerId] = nil
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

    func refresh(_ providerId: String) async {
        guard let provider = provider(for: providerId) else { return }
        if settings.isConnected(providerId) {
            refreshingIds.insert(providerId)
            defer { refreshingIds.remove(providerId) }
            do {
                let snapshot = try await provider.fetchUsage()
                lastLive[providerId] = snapshot
                snapshots[providerId] = snapshot
                lastErrors[providerId] = nil
            } catch {
                let failure = (error as? ConnectionError) ?? .unreadable(error.localizedDescription)
                lastErrors[providerId] = failure
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
