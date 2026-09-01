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
}

@MainActor
final class ProviderManager: ObservableObject {
    let providers: [any UsageProviding]
    let allProviderInfos: [ProviderInfo]

    @Published private(set) var snapshots: [String: UsageSnapshot] = [:]

    private let settings: AppSettings
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
                installed: $0.isInstalled()
            )
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
            ChatGPTProvider(),
            GeminiProvider(),
            CopilotProvider(),
        ]
    }

    var enabledProviderInfos: [ProviderInfo] {
        allProviderInfos.filter { settings.isEnabled($0.id) }
    }

    func providerInfo(for id: String) -> ProviderInfo? {
        allProviderInfos.first { $0.id == id }
    }

    func snapshot(for id: String) -> UsageSnapshot? {
        snapshots[id]
    }

    func start() {
        Task { await refreshAll() }
        restartTimer(interval: settings.refreshInterval)
    }

    func refreshAll() async {
        for provider in providers {
            snapshots[provider.id] = await provider.fetchUsage()
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
