import AppKit
import Combine
import SwiftUI
import UserNotifications

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
        // Before anything else, as Apple requires: a click that launches
        // AIrail, or an alert arriving while it is active, must find us.
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories([UpdateChecker.notificationCategory])
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
        // The tests drive ProviderManager with fakes; the host app they run
        // in must not poll live endpoints (or prompt for the Keychain) too.
        if !LaunchOptions.isRunningTests {
            HTTPClient.removeLegacyStores() // v0.2.0's cache and cookie jar, before the first read
            providerManager.start()
            UpdateChecker.startBackgroundChecks { [weak self] release in
                self?.uiState.availableUpdate = release // the menus read "Update to x.y.z…"
            }
        }

        if let providerId = LaunchOptions.overlayProviderId {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak overlay] in
                overlay?.toggle(providerId: providerId)
            }
        }

        Publishers.Merge(
            settings.$position.dropFirst().map { _ in () },
            settings.$railDisplay.dropFirst().map { _ in () }
        )
        .sink { [weak self] in
            self?.overlayController?.close()
            self?.applyPosition(resettling: true)
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

        // Displays come and go: the notch may appear (lid opened) or vanish
        // (clamshell), and a chosen display may reattach. The screen list often
        // isn't final the instant the notification fires, so re-assert after a
        // short settle too.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.overlayController?.close()
                self?.applyPosition(resettling: true)
            }
            .store(in: &cancellables)

        // The screen list can still be settling at launch (external displays,
        // wake-from-sleep); re-assert once it has.
        applyPosition(resettling: true)
    }

    /// The notch the island hangs from for Top: the hardware one when the
    /// chosen display has it, else a drawn one at the top centre of the chosen
    /// display; nil for the edge rail.
    private func resolveNotch() -> NotchGeometry.Notch? {
        switch settings.position {
        case .top:
            if ScreenSelection.notchAvailable(preference: settings.railDisplay) { return NotchGeometry.notch() }
            return ScreenSelection.islandScreen(preference: settings.railDisplay).map(NotchGeometry.virtualNotch(on:))
        case .left, .right:
            return nil
        }
    }

    /// Puts the rail on the chosen edge, or hangs the island from a notch
    /// (real or drawn) — otherwise the left edge stands in. `resettling` runs
    /// it again after a short delay, for when the screen list is still settling.
    private func applyPosition(resettling: Bool = false) {
        applyPosition()
        if resettling {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.applyPosition()
            }
        }
    }

    private func applyPosition() {
        notchController?.resolveNotch = { [weak self] in self?.resolveNotch() }
        let wantsNotch = resolveNotch() != nil
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

    /// A notification click: the active surface expands as if hovered and
    /// the HUD opens on that account (swapping if it's open on another).
    private func showOverlay(providerId: String) {
        guard settings.isConnected(providerId) else { return } // removed since the alert
        if usingNotch {
            notchController?.expand()
        } else {
            railController?.expand()
        }
        overlayController?.show(providerId: providerId)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !LaunchOptions.isRunningTests {
            providerManager.stop()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

// MARK: - Notification Center

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Nothing AIrail shows covers what an alert says, so one arriving while
    /// it is the active app (the Settings window key) still gets its banner.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    /// Every usage alert names its account (`UsageNotifier`); clicking one
    /// opens that HUD. The update notification carries its links instead:
    /// its Download button opens the DMG, a click the release page — in the
    /// browser, with AIrail staying where it is (`UpdateChecker`).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        if content.categoryIdentifier == UpdateChecker.categoryIdentifier {
            guard let url = UpdateChecker.destination(for: response.actionIdentifier, in: content.userInfo) else { return }
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
            return
        }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let providerId = content.userInfo["providerId"] as? String
        else { return }
        await MainActor.run { showOverlay(providerId: providerId) }
    }
}
