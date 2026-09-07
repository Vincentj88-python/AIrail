import Foundation
import Combine

/// Shared UI state between the rail and the overlay.
@MainActor
final class RailUIState: ObservableObject {
    enum SettingsTab: String, Hashable {
        case general, rail, accounts, privacy
    }

    @Published var isExpanded = false
    @Published var selectedProviderId: String?
    /// Size of the notch the island hangs from, in points; zero without one.
    @Published var notchSize: CGSize = .zero
    /// True when that "notch" is drawn by AIrail rather than cut into the display.
    @Published var notchIsVirtual = false
    /// Which Settings tab opens next; the overlay's "Connect…" jumps to Accounts.
    @Published var settingsTab: SettingsTab = .general
    /// The newer release the last update check found, nil when there is none
    /// (or no check has answered yet); the menus read "Update to x.y.z…" while set.
    @Published var availableUpdate: UpdateChecker.Release?
}
