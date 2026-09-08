import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    enum RailSide: String, CaseIterable, Identifiable {
        case left, right
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    /// Where the rail lives: a screen edge, folded into the MacBook notch, or
    /// as a drawn island at the top centre of a display without one.
    enum RailPosition: String, CaseIterable, Identifiable {
        case left, right, top
        var id: String { rawValue }
        var label: String {
            switch self {
            case .left: return "Left"
            case .right: return "Right"
            case .top: return "Top"
            }
        }
        /// Top hangs from the notch where the display has one and from a
        /// hairline at the top centre where it doesn't; the edge rail differs.
        var isTop: Bool { self == .top }
    }

    private enum Key {
        static let railSide = "railSide"
        static let railPosition = "railPosition"
        static let railDisplay = "railDisplay"
        static let autoHideDelay = "autoHideDelay"
        static let railAutoHides = "railAutoHides"
        static let refreshInterval = "refreshInterval"
        static let connectedAccounts = "connectedAccounts"
        static let hiddenFromRail = "hiddenFromRail"
        static let notifications = "notificationsEnabled"
    }

    static let toolProviderIds = ["cursor", "claude", "codex", "gemini", "copilot"]
    static let platformProviderIds = ["openrouter", "deepseek", "anthropic-api", "openai-api"]
    static let allProviderIds = toolProviderIds + platformProviderIds

    @Published var position: RailPosition {
        didSet { defaults.set(position.rawValue, forKey: Key.railPosition) }
    }

    /// The edge the rail hugs; notch mode falls back to the left edge when no
    /// notched display is around.
    var railSide: RailSide {
        position == .right ? .right : .left
    }
    /// A display's name, or `ScreenSelection.automatic` for the outer edge of
    /// the whole arrangement.
    @Published var railDisplay: String {
        didSet { defaults.set(railDisplay, forKey: Key.railDisplay) }
    }
    @Published var autoHideDelay: Double {
        didSet { defaults.set(autoHideDelay, forKey: Key.autoHideDelay) }
    }
    /// Dock-style "Automatically hide the rail". Off, the edge rail stays
    /// open as the stack of marks and never tucks back into the hairline.
    /// Top ignores it: a permanent island under the notch would be odd.
    @Published var railAutoHides: Bool {
        didSet { defaults.set(railAutoHides, forKey: Key.railAutoHides) }
    }
    /// True when the edge rail should sit open all day.
    var railIsPinned: Bool {
        !railAutoHides && !position.isTop
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
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notifications) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.string(forKey: Key.railPosition) {
            // v0.2 kept Notch and Island as two positions; both are Top now.
            position = RailPosition(rawValue: stored) ?? (["notch", "island"].contains(stored) ? .top : .left)
        } else {
            // v0.1 stored only a side.
            position = defaults.string(forKey: Key.railSide) == "right" ? .right : .left
        }
        railDisplay = defaults.string(forKey: Key.railDisplay) ?? ScreenSelection.automatic
        autoHideDelay = defaults.object(forKey: Key.autoHideDelay) as? Double ?? 0.3
        railAutoHides = defaults.object(forKey: Key.railAutoHides) as? Bool ?? true
        refreshInterval = defaults.object(forKey: Key.refreshInterval) as? Double ?? 60
        // Off until asked for: the permission prompt comes with the toggle.
        notificationsEnabled = defaults.object(forKey: Key.notifications) as? Bool ?? false
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
