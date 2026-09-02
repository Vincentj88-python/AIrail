import AppKit
import SwiftUI

/// The rail folded into the MacBook notch — or into a drawn island on a
/// display without one. Collapsed, only a hairline shows under the notch (plus
/// the pill itself when drawn); on hover the notch grows down into a Dynamic
/// Island-style row of marks. Same three states and timings as the edge rail.
@MainActor
final class NotchWindowController {
    var onSelect: (@MainActor (String) -> Void)?
    var isOverlayOpen: (@MainActor () -> Bool) = { false }
    /// Which notch to hang from — the hardware one or a drawn one — decided by
    /// the app from the position and display settings.
    var resolveNotch: (@MainActor () -> NotchGeometry.Notch?) = { nil }

    static let hairlineZone: CGFloat = 10
    static let markSize: CGFloat = 40
    static let markSpacing: CGFloat = 12
    static let islandPadding: CGFloat = 20
    static let islandFlare: CGFloat = 16
    static let islandBodyHeight: CGFloat = markSize + 32 // marks + caption row

    private let panel: RailPanel
    private let settings: AppSettings
    private let manager: ProviderManager
    private let ui: RailUIState
    private var collapseTask: Task<Void, Never>?
    private(set) var notch: NotchGeometry.Notch?

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
        // Above the menu bar, so the island can grow out of the notch.
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.appearance = NSAppearance(named: .darkAqua)

        let tracking = HoverTrackingView()
        tracking.onEnter = { [weak self] in self?.expand() }
        tracking.onExit = { [weak self] in self?.scheduleCollapse() }

        let notchView = NotchView(settings: settings, manager: manager, ui: ui) { [weak self] providerId in
            self?.onSelect?(providerId)
        }
        let host = NSHostingView(rootView: notchView)
        host.translatesAutoresizingMaskIntoConstraints = false
        tracking.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: tracking.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: tracking.trailingAnchor),
            host.topAnchor.constraint(equalTo: tracking.topAnchor),
            host.bottomAnchor.constraint(equalTo: tracking.bottomAnchor),
        ])
        panel.contentView = tracking
    }

    var isVisible: Bool { panel.isVisible }

    /// Shows the island on the notched display, if there is one right now.
    func show() {
        reposition()
        guard notch != nil else { return }
        panel.orderFrontRegardless()
    }

    func hide() {
        collapseTask?.cancel()
        collapseTask = nil
        ui.isExpanded = false
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
        let delay = max(0, settings.autoHideDelay)
        collapseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.isOverlayOpen() else { return }
            self.collapse()
        }
    }

    func scheduleCollapseIfIdle() {
        if !panel.frame.contains(NSEvent.mouseLocation) {
            scheduleCollapse()
        }
    }

    /// Re-resolves the notch (displays come and go) and refits the panel.
    func reposition() {
        notch = resolveNotch()
        guard let notch else {
            panel.orderOut(nil)
            return
        }
        panel.setFrame(frame(expanded: ui.isExpanded), display: true)
        ui.notchSize = notch.rect.size
        ui.notchIsVirtual = notch.isVirtual
    }

    func expandedFrame() -> NSRect {
        frame(expanded: true)
    }

    private func collapse() {
        ui.isExpanded = false
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 380_000_000)
            guard let self, !self.ui.isExpanded else { return }
            self.panel.setFrame(self.frame(expanded: false), display: true)
        }
    }

    /// Collapsed: the notch plus a thin hoverable zone under it. Expanded: the
    /// island, at least as wide as the notch, centred on it, hanging from the
    /// top of the screen.
    private func frame(expanded: Bool) -> NSRect {
        guard let notch else { return .zero }
        let rect = notch.rect
        if expanded {
            let count = max(1, manager.railProviderInfos.count)
            let content = CGFloat(count) * Self.markSize + CGFloat(count - 1) * Self.markSpacing + Self.islandPadding * 2
            // The body is at least the notch's width; flare adds room on each
            // side for the concave top fillets to reach the full top edge.
            let body = max(rect.width, content)
            let width = (body + Self.islandFlare * 2).rounded()
            let height = rect.height + Self.islandBodyHeight
            return NSRect(x: (rect.midX - width / 2).rounded(), y: rect.maxY - height, width: width, height: height)
        }
        let height = rect.height + Self.hairlineZone
        return NSRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height)
    }
}
