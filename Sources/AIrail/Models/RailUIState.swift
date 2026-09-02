import Foundation
import Combine

/// Shared UI state between the rail and the overlay.
@MainActor
final class RailUIState: ObservableObject {
    enum SettingsTab: String, Hashable {
        case general, rail, accounts
    }

    @Published var isExpanded = false
    @Published var selectedProviderId: String?
    /// Which Settings tab opens next; the overlay's "Connect…" jumps to Accounts.
    @Published var settingsTab: SettingsTab = .general
}
