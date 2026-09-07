import AppKit
import SwiftUI

/// Spotlight-style HUD panel: becomes key without activating the app,
/// so Escape works while the user's frontmost app stays frontmost.
final class OverlayPanel: NSPanel {
    var onEscape: (@MainActor () -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class OverlayWindowController {
    var onClose: (@MainActor () -> Void)?
    var railFrameProvider: (@MainActor () -> NSRect?)?
    /// Notch mode hangs the HUD under the island instead of beside the rail.
    var anchorsBelow = false

    private let panel: OverlayPanel
    private let settings: AppSettings
    private let ui: RailUIState
    private var clickMonitor: Any?

    var isVisible: Bool { panel.isVisible }

    init(settings: AppSettings, manager: ProviderManager, ui: RailUIState) {
        self.settings = settings
        self.ui = ui

        panel = OverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.onEscape = { [weak self] in self?.close() }

        let host = NSHostingView(rootView: OverlayView(settings: settings, manager: manager, ui: ui))
        panel.contentView = host
    }

    /// Click a logo: open, swap provider, or close when it's the same logo.
    func toggle(providerId: String) {
        if isVisible && ui.selectedProviderId == providerId {
            close()
            return
        }
        show(providerId: providerId)
    }

    /// Open on (or swap to) a provider without ever closing — a notification click.
    func show(providerId: String) {
        ui.selectedProviderId = providerId
        show()
    }

    func close() {
        guard isVisible || ui.selectedProviderId != nil else { return }
        removeClickMonitor()
        panel.orderOut(nil)
        ui.selectedProviderId = nil
        onClose?()
    }

    private func show() {
        layout()
        panel.makeKeyAndOrderFront(nil)
        installClickMonitor()
        // Content height can change with the provider; settle once SwiftUI has laid out.
        Task { @MainActor [weak self] in
            self?.layout()
        }
    }

    private func layout() {
        let rail = railFrameProvider?() ?? .zero
        // Stay on whichever display the rail or island is on.
        let screen = NSScreen.screens.first { $0.frame.intersects(rail) } ?? NSScreen.screens.first ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        var size = panel.contentView?.fittingSize ?? .zero
        if size.width < 100 || size.height < 100 {
            size = NSSize(width: 480, height: 620)
        }
        let gap: CGFloat = 10

        var x: CGFloat
        var y: CGFloat
        if anchorsBelow {
            x = rail.midX - size.width / 2
            y = rail.minY - gap - size.height
        } else {
            x = settings.railSide == .left
                ? rail.maxX + gap
                : rail.minX - gap - size.width
            y = rail.maxY - size.height // top-align the HUD with the rail
        }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)

        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
    }

    private func installClickMonitor() {
        removeClickMonitor()
        // Global monitor only sees clicks in *other* apps — exactly "click outside".
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.close()
            }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }
}
