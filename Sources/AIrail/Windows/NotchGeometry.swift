import AppKit

/// Where the MacBook notch is, from the screen's own safe-area description —
/// or where a drawn one goes on a display that has none.
enum NotchGeometry {
    struct Notch: Equatable {
        let screen: NSScreen
        /// The notch's rectangle in global screen coordinates (origin bottom-left).
        let rect: NSRect
        /// True for the island drawn on a display without a hardware notch.
        var isVirtual = false

        static func == (lhs: Notch, rhs: Notch) -> Bool {
            lhs.rect == rhs.rect && lhs.screen == rhs.screen && lhs.isVirtual == rhs.isVirtual
        }
    }

    static let virtualWidth: CGFloat = 200

    /// Where the island hangs from on a display without a hardware notch: the
    /// top centre, as tall as the menu bar (nothing is drawn there when idle;
    /// the hairline sits just below, and the island grows out of it on hover).
    /// A display without a menu bar has no such band, so the hairline sits at
    /// the very top.
    static func virtualNotch(on screen: NSScreen) -> Notch {
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return Notch(screen: screen, rect: virtualRect(in: screen.frame, menuBarHeight: menuBar), isVirtual: true)
    }

    static func virtualRect(in frame: NSRect, menuBarHeight: CGFloat) -> NSRect {
        let height = max(0, menuBarHeight.rounded())
        return NSRect(
            x: (frame.midX - virtualWidth / 2).rounded(),
            y: frame.maxY - height,
            width: virtualWidth,
            height: height
        )
    }

    /// True when the display physically has a notch. Keyed on the safe-area
    /// inset — the one signal that's reliable whether or not the display holds
    /// the menu bar — so this agrees with `notch()` below.
    static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0
    }

    /// The first attached display with a notch, or nil (external displays,
    /// older MacBooks, clamshell mode). The notch height comes from the safe
    /// area; its width from the auxiliary areas when macOS reports them, else a
    /// centred default — so a notched display always resolves to a notch,
    /// never silently falls back to an edge.
    static func notch() -> Notch? {
        guard let screen = NSScreen.screens.first(where: hasNotch) else { return nil }
        let height = screen.safeAreaInsets.top
        let rect: NSRect
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            rect = NSRect(x: left.maxX, y: screen.frame.maxY - height, width: right.minX - left.maxX, height: height)
        } else {
            let width = virtualWidth
            rect = NSRect(x: (screen.frame.midX - width / 2).rounded(), y: screen.frame.maxY - height, width: width, height: height)
        }
        return Notch(screen: screen, rect: rect)
    }
}
