import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    let uiState = RailUIState()
    private(set) lazy var providerManager = ProviderManager(settings: settings)

    private var railController: RailWindowController?
    private var notchController: NotchWindowController?
    private var overlayController: OverlayWindowController?
    private var cancellables: Set<AnyCancellable> = []

    /// True while the island is the thing on screen (notch mode with a
    /// notched display attached); otherwise the edge rail is.
    private var usingNotch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let rail = RailWindowController(settings: settings, manager: providerManager, ui: uiState)
        let notch = NotchWindowController(settings: settings, manager: providerManager, ui: uiState)
        let overlay = OverlayWindowController(settings: settings, manager: providerManager, ui: uiState)
        railController = rail
        notchController = notch
        overlayController = overlay

        rail.onSelect = { [weak overlay] providerId in
            overlay?.toggle(providerId: providerId)
        }
        notch.onSelect = { [weak overlay] providerId in
            overlay?.toggle(providerId: providerId)
        }
        rail.isOverlayOpen = { [weak overlay] in
            overlay?.isVisible ?? false
        }
        notch.isOverlayOpen = { [weak overlay] in
            overlay?.isVisible ?? false
        }
        overlay.onClose = { [weak self] in
            guard let self else { return }
            if usingNotch {
                notchController?.scheduleCollapseIfIdle()
            } else {
                railController?.scheduleCollapseIfIdle()
            }
        }
        overlay.railFrameProvider = { [weak self] in
            guard let self else { return nil }
            return usingNotch ? notchController?.expandedFrame() : railController?.expandedFrame()
        }

        applyPosition()
        providerManager.start()

        if let providerId = LaunchOptions.overlayProviderId {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak overlay] in
                overlay?.toggle(providerId: providerId)
            }
        }

        settings.$position
            .dropFirst()
            .sink { [weak self] _ in
                self?.overlayController?.close()
                self?.applyPosition()
            }
            .store(in: &cancellables)

        // Rail membership follows the connected accounts and their show-on-rail toggles.
        Publishers.Merge(
            settings.$connectedAccountIds.dropFirst().map { _ in () },
            settings.$hiddenFromRailIds.dropFirst().map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            guard let self else { return }
            let shown = Set(providerManager.railProviderInfos.map(\.id))
            if let selected = uiState.selectedProviderId, !shown.contains(selected) {
                overlayController?.close()
            }
            reposition() // rail height / island width follow provider count
        }
        .store(in: &cancellables)

        // Displays come and go: the notch may appear (lid opened) or vanish (clamshell).
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.overlayController?.close()
                self?.applyPosition()
            }
            .store(in: &cancellables)
    }

    /// Puts the rail on the chosen edge, or into the notch when asked and a
    /// notched display is attached — otherwise the left edge stands in.
    private func applyPosition() {
        let wantsNotch = settings.position == .notch && NotchGeometry.notch() != nil
        if wantsNotch != usingNotch {
            uiState.isExpanded = false
        }
        usingNotch = wantsNotch
        overlayController?.anchorsBelow = wantsNotch
        if wantsNotch {
            railController?.hide()
            notchController?.show()
        } else {
            notchController?.hide()
            railController?.reposition()
            railController?.show()
        }
    }

    private func reposition() {
        if usingNotch {
            notchController?.reposition()
        } else {
            railController?.reposition()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
