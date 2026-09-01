import Foundation
import Combine

/// Shared UI state between the rail and the overlay.
@MainActor
final class RailUIState: ObservableObject {
    @Published var isExpanded = false
    @Published var selectedProviderId: String?
}
