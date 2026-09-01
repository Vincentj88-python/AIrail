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
        static let enabledProviders = "enabledProviders"
    }

    static let allProviderIds = ["cursor", "claude", "codex", "chatgpt", "gemini", "copilot"]

    @Published var railSide: RailSide {
        didSet { defaults.set(railSide.rawValue, forKey: Key.railSide) }
    }
    @Published var autoHideDelay: Double {
        didSet { defaults.set(autoHideDelay, forKey: Key.autoHideDelay) }
    }
    @Published var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: Key.refreshInterval) }
    }
    @Published var enabledProviderIds: Set<String> {
        didSet { defaults.set(Array(enabledProviderIds).sorted(), forKey: Key.enabledProviders) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        railSide = RailSide(rawValue: defaults.string(forKey: Key.railSide) ?? "") ?? .left
        autoHideDelay = defaults.object(forKey: Key.autoHideDelay) as? Double ?? 0.3
        refreshInterval = defaults.object(forKey: Key.refreshInterval) as? Double ?? 60
        if let stored = defaults.stringArray(forKey: Key.enabledProviders) {
            enabledProviderIds = Set(stored)
        } else {
            enabledProviderIds = Set(Self.allProviderIds)
        }
    }

    func isEnabled(_ providerId: String) -> Bool {
        enabledProviderIds.contains(providerId)
    }

    func setEnabled(_ enabled: Bool, providerId: String) {
        if enabled {
            enabledProviderIds.insert(providerId)
        } else {
            enabledProviderIds.remove(providerId)
        }
    }
}
