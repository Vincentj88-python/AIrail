import AppKit

/// Which display the edge rail lives on. A rail only works on an edge the
/// pointer actually stops at, so "Automatic" picks the outer edge of the whole
/// arrangement for the chosen side — never a seam between two displays.
enum ScreenSelection {
    static let automatic = "auto"

    static func railScreen(preference: String, side: AppSettings.RailSide) -> NSScreen? {
        let screens = NSScreen.screens
        if preference != automatic, let named = screens.first(where: { $0.localizedName == preference }) {
            return named
        }
        return outerScreen(side: side, among: screens)
    }

    /// Leftmost (or rightmost) display; the taller one wins a tie so the rail
    /// has room. `NSScreen.main` is the fallback when nothing is attached.
    static func outerScreen(side: AppSettings.RailSide, among screens: [NSScreen]) -> NSScreen? {
        guard let index = outerIndex(side: side, frames: screens.map(\.frame)) else { return NSScreen.main }
        return screens[index]
    }

    static func outerIndex(side: AppSettings.RailSide, frames: [NSRect]) -> Int? {
        let indexed = Array(frames.enumerated())
        switch side {
        case .left:
            return indexed.min { ($0.element.minX, -$0.element.height) < ($1.element.minX, -$1.element.height) }?.offset
        case .right:
            return indexed.max { ($0.element.maxX, $0.element.height) < ($1.element.maxX, $1.element.height) }?.offset
        }
    }

    static func screen(named name: String) -> NSScreen? {
        NSScreen.screens.first { $0.localizedName == name }
    }

    static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0
    }

    /// Whether the Notch position makes sense for a display choice: the
    /// chosen display must be the one with the notch (Automatic accepts any).
    static func notchAvailable(preference: String) -> Bool {
        guard NotchGeometry.notch() != nil else { return false }
        if preference == automatic { return true }
        return screen(named: preference).map(hasNotch) ?? false
    }

    /// The display the pointer would cross onto past the rail's edge, if any —
    /// the edge is then a seam, not somewhere the pointer can rest.
    static func neighbour(beyond screen: NSScreen, side: AppSettings.RailSide) -> NSScreen? {
        let others = NSScreen.screens.filter { $0 != screen }
        guard let index = neighbourIndex(beyond: screen.frame, side: side, frames: others.map(\.frame)) else { return nil }
        return others[index]
    }

    static func neighbourIndex(beyond frame: NSRect, side: AppSettings.RailSide, frames: [NSRect]) -> Int? {
        frames.firstIndex { other in
            let touches = side == .left
                ? abs(other.maxX - frame.minX) < 1
                : abs(other.minX - frame.maxX) < 1
            return touches && other.minY < frame.maxY && other.maxY > frame.minY
        }
    }

    /// Names for the Settings popup, in the order macOS lists the displays.
    static var displayNames: [String] {
        var seen: Set<String> = []
        return NSScreen.screens.map(\.localizedName).filter { seen.insert($0).inserted }
    }
}
