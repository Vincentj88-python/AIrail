import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    let uiState = RailUIState()
    private(set) lazy var providerManager = ProviderManager(settings: settings)

    private var railController: RailWindowController?
    private var overlayController: OverlayWindowController?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let rail = RailWindowController(settings: settings, manager: providerManager, ui: uiState)
        let overlay = OverlayWindowController(settings: settings, manager: providerManager, ui: uiState)
        railController = rail
        overlayController = overlay

        rail.onSelect = { [weak overlay] providerId in
            overlay?.toggle(providerId: providerId)
        }
        rail.isOverlayOpen = { [weak overlay] in
            overlay?.isVisible ?? false
        }
        overlay.onClose = { [weak rail] in
            rail?.scheduleCollapseIfIdle()
        }
        overlay.railFrameProvider = { [weak rail] in
            rail?.expandedFrame()
        }

        rail.show()
        providerManager.start()

        settings.$railSide
            .dropFirst()
            .sink { [weak self] _ in
                self?.overlayController?.close()
                self?.railController?.reposition()
            }
            .store(in: &cancellables)

        settings.$enabledProviderIds
            .dropFirst()
            .sink { [weak self] enabled in
                if let selected = self?.uiState.selectedProviderId, !enabled.contains(selected) {
                    self?.overlayController?.close()
                }
                self?.railController?.reposition() // rail height follows provider count
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.overlayController?.close()
                self?.railController?.reposition()
            }
            .store(in: &cancellables)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
