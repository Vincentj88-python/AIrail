import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    enum RailSide: String, CaseIterable, Identifiable {
        case left, right
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    private enum Key {
        static let railSide = "railSide"
        static let autoHideDelay = "autoHideDelay"
        static let refreshInterval = "refreshInterval"
        static let connectedAccounts = "connectedAccounts"
        static let hiddenFromRail = "hiddenFromRail"
    }

    static let allProviderIds = ["cursor", "claude", "codex", "gemini", "copilot"]

    @Published var railSide: RailSide {
        didSet { defaults.set(railSide.rawValue, forKey: Key.railSide) }
    }
    @Published var autoHideDelay: Double {
        didSet { defaults.set(autoHideDelay, forKey: Key.autoHideDelay) }
    }
    @Published var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: Key.refreshInterval) }
    }
    /// Accounts the user has connected. Only ids in here are ever read live;
    /// with none connected the rail falls back to demo data.
    @Published var connectedAccountIds: Set<String> {
        didSet { defaults.set(Array(connectedAccountIds).sorted(), forKey: Key.connectedAccounts) }
    }
    /// Connected accounts the user has taken off the rail (still refreshed,
    /// still listed in Settings).
    @Published var hiddenFromRailIds: Set<String> {
        didSet { defaults.set(Array(hiddenFromRailIds).sorted(), forKey: Key.hiddenFromRail) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        railSide = RailSide(rawValue: defaults.string(forKey: Key.railSide) ?? "") ?? .left
        autoHideDelay = defaults.object(forKey: Key.autoHideDelay) as? Double ?? 0.3
        refreshInterval = defaults.object(forKey: Key.refreshInterval) as? Double ?? 60
        connectedAccountIds = Set(defaults.stringArray(forKey: Key.connectedAccounts) ?? [])
        hiddenFromRailIds = Set(defaults.stringArray(forKey: Key.hiddenFromRail) ?? [])
        // v0.1 stored "enabled providers"; accounts replaced that concept.
        defaults.removeObject(forKey: "enabledProviders")
    }

    var hasConnectedAccounts: Bool {
        !connectedAccountIds.isEmpty
    }

    func isConnected(_ providerId: String) -> Bool {
        connectedAccountIds.contains(providerId)
    }

    func connect(_ providerId: String) {
        connectedAccountIds.insert(providerId)
        hiddenFromRailIds.remove(providerId)
    }

    func disconnect(_ providerId: String) {
        connectedAccountIds.remove(providerId)
        hiddenFromRailIds.remove(providerId)
    }

    func isShownOnRail(_ providerId: String) -> Bool {
        isConnected(providerId) && !hiddenFromRailIds.contains(providerId)
    }

    func setShownOnRail(_ shown: Bool, providerId: String) {
        if shown {
            hiddenFromRailIds.remove(providerId)
        } else {
            hiddenFromRailIds.insert(providerId)
        }
    }
}
