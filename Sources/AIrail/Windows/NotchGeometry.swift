import AppKit

/// Where the MacBook notch is, from the screen's own safe-area description.
enum NotchGeometry {
    struct Notch: Equatable {
        let screen: NSScreen
        /// The notch's rectangle in global screen coordinates (origin bottom-left).
        let rect: NSRect

        static func == (lhs: Notch, rhs: Notch) -> Bool {
            lhs.rect == rhs.rect && lhs.screen == rhs.screen
        }
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
