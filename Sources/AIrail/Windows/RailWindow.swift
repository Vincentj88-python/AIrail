import AppKit
import SwiftUI

/// The rail must never take key focus; hovering it should not steal
/// the keyboard from whatever the user is doing.
final class RailPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Container view that reports mouse enter/exit for the whole rail.
final class HoverTrackingView: NSView {
    var onEnter: (@MainActor () -> Void)?
    var onExit: (@MainActor () -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

@MainActor
final class RailWindowController {
    var onSelect: (@MainActor (String) -> Void)?
    var isOverlayOpen: (@MainActor () -> Bool) = { false }

    private let panel: RailPanel
    private let settings: AppSettings
    private let manager: ProviderManager
    private let ui: RailUIState
    private var collapseTask: Task<Void, Never>?

    private let collapsedWidth: CGFloat = 10
    private let expandedWidth: CGFloat = 108

    init(settings: AppSettings, manager: ProviderManager, ui: RailUIState) {
        self.settings = settings
        self.manager = manager
        self.ui = ui

        panel = RailPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        // The rail is a dark-glass HUD in either system appearance.
        panel.appearance = NSAppearance(named: .darkAqua)

        let tracking = HoverTrackingView()
        tracking.onEnter = { [weak self] in self?.expand() }
        tracking.onExit = { [weak self] in self?.scheduleCollapse() }

        let railView = RailView(settings: settings, manager: manager, ui: ui) { [weak self] providerId in
            self?.onSelect?(providerId)
        }
        let host = NSHostingView(rootView: railView)
        host.translatesAutoresizingMaskIntoConstraints = false
        tracking.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: tracking.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: tracking.trailingAnchor),
            host.topAnchor.constraint(equalTo: tracking.topAnchor),
            host.bottomAnchor.constraint(equalTo: tracking.bottomAnchor),
        ])
        panel.contentView = tracking

        reposition()
    }

    func show() {
        panel.orderFrontRegardless()
        if settings.railIsPinned {
            expand()
        }
    }

    func hide() {
        collapseTask?.cancel()
        collapseTask = nil
        panel.orderOut(nil)
    }

    func expand() {
        collapseTask?.cancel()
        collapseTask = nil
        guard !ui.isExpanded else { return }
        panel.setFrame(frame(expanded: true), display: true)
        ui.isExpanded = true
    }

    func scheduleCollapse() {
        collapseTask?.cancel()
        guard !settings.railIsPinned else { return }
        let delay = max(0, settings.autoHideDelay)
        collapseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.isOverlayOpen() else { return }
            self.collapse()
        }
    }

    /// Called when the overlay closes: collapse unless the pointer is on the rail.
    func scheduleCollapseIfIdle() {
        if !panel.frame.contains(NSEvent.mouseLocation) {
            scheduleCollapse()
        }
    }

    /// The auto-hide setting changed: pinned opens the rail and keeps it;
    /// unpinned lets it tuck away unless the pointer or the card is holding it.
    func applyAutoHide() {
        if settings.railIsPinned {
            expand()
        } else {
            scheduleCollapseIfIdle()
        }
    }

    func reposition() {
        panel.setFrame(frame(expanded: ui.isExpanded), display: true)
    }

    func expandedFrame() -> NSRect {
        frame(expanded: true)
    }

    private func collapse() {
        ui.isExpanded = false
        // Shrink the hit target once the collapse animation has settled.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 380_000_000)
            guard let self, !self.ui.isExpanded else { return }
            self.panel.setFrame(self.frame(expanded: false), display: true)
        }
    }

    private func frame(expanded: Bool) -> NSRect {
        guard let screen = ScreenSelection.railScreen(preference: settings.railDisplay, side: settings.railSide) else {
            return .zero
        }
        let visible = screen.visibleFrame
        // Expanded fits the card exactly: each cell is a 44 pt mark plus a
        // two-line caption (name + percent, ~31 pt); 16 pt gaps; card padding.
        let count = max(1, manager.railProviderInfos.count)
        let cellHeight: CGFloat = 44 + 5 + 31
        let expandedHeight = min(
            CGFloat(count) * cellHeight + CGFloat(count - 1) * 16 + 32 + 24,
            visible.height - 20
        )
        // Collapsed is just a compact hover strip — a short centred hairline,
        // not a full-height line. It grows to the card height on hover.
        let collapsedHeight = min(expandedHeight, 168)
        let height = (expanded ? expandedHeight : collapsedHeight).rounded()
        let y = (visible.midY - height / 2).rounded()
        let width: CGFloat = expanded ? expandedWidth : collapsedWidth
        let x = settings.railSide == .left ? visible.minX : visible.maxX - width
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
