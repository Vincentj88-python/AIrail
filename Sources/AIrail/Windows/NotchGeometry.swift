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
    static let virtualMinHeight: CGFloat = 28

    /// A Dynamic Island-style pill at the top centre of `screen`, as tall as
    /// its menu bar so it reads as part of the bar.
    static func virtualNotch(on screen: NSScreen) -> Notch {
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return Notch(screen: screen, rect: virtualRect(in: screen.frame, menuBarHeight: menuBar), isVirtual: true)
    }

    static func virtualRect(in frame: NSRect, menuBarHeight: CGFloat) -> NSRect {
        let height = max(virtualMinHeight, menuBarHeight.rounded())
        return NSRect(
            x: (frame.midX - virtualWidth / 2).rounded(),
            y: frame.maxY - height,
            width: virtualWidth,
            height: height
        )
    }

    /// The first attached display with a notch, or nil (external displays,
    /// older MacBooks, clamshell mode).
    static func notch() -> Notch? {
        for screen in NSScreen.screens {
            guard screen.safeAreaInsets.top > 0,
                  let left = screen.auxiliaryTopLeftArea,
                  let right = screen.auxiliaryTopRightArea
            else { continue }
            let height = screen.safeAreaInsets.top
            let rect = NSRect(
                x: left.maxX,
                y: screen.frame.maxY - height,
                width: right.minX - left.maxX,
                height: height
            )
            guard rect.width > 0 else { continue }
            return Notch(screen: screen, rect: rect)
        }
        return nil
    }
}
