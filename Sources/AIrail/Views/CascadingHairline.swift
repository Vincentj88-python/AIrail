import SwiftUI

/// Collapsed-state hairline: a 3 pt line that wears ONE provider color at a
/// time. Each color holds for a few seconds, then the next enabled provider's
/// color washes along the bar. Never a rainbow — at most two colors are
/// visible, and only during the handoff. Runs vertically on the edge rail,
/// horizontally under the notch.
struct CascadingHairline: View {
    var colors: [Color]
    var reduceMotion: Bool
    var axis: Axis = .vertical

    /// Seconds each color owns the bar (hold + handoff).
    private static let perColorDuration: Double = 8

    private var displayColors: [Color] {
        guard let first = colors.first else {
            return [Color.teal.opacity(0.7), Color.teal.opacity(0.35)]
        }
        if colors.count == 1 {
            // Single provider: breathe between two intensities of its color.
            return [first.opacity(0.85), first.opacity(0.4)]
        }
        return colors
    }

    /// One bar-length zone per color: 75% solid hold, 25% blend into the next.
    private var stripGradient: Gradient {
        let palette = displayColors
        let count = Double(palette.count)
        var stops: [Gradient.Stop] = []
        for (index, color) in palette.enumerated() {
            let start = Double(index) / count
            stops.append(.init(color: color, location: start))
            stops.append(.init(color: color, location: start + 0.75 / count))
        }
        stops.append(.init(color: palette[0], location: 1))
        return Gradient(stops: stops)
    }

    var body: some View {
        GeometryReader { geo in
            let length = axis == .vertical ? geo.size.height : geo.size.width
            let loopDuration = Self.perColorDuration * Double(max(1, displayColors.count))
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                let phase = reduceMotion
                    ? 0
                    : CGFloat((time / loopDuration).truncatingRemainder(dividingBy: 1))
                ZStack {
                    // soft glow, cascading in sync with the core
                    band(length: length, phase: phase)
                        .frame(width: thickness(5), height: thickness(5, horizontal: true))
                        .blur(radius: 4)
                        .opacity(0.32)
                    // core line, kept muted
                    band(length: length, phase: phase)
                        .frame(width: thickness(3), height: thickness(3, horizontal: true))
                        .opacity(0.72)
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                        )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The bar's cross-axis size; nil lets the other axis fill.
    private func thickness(_ value: CGFloat, horizontal: Bool = false) -> CGFloat? {
        (axis == .vertical) != horizontal ? value : nil
    }

    /// The full color strip is `count` bar-lengths long, so the visible window
    /// shows a single color zone at a time. Doubled and scrolled by `phase`,
    /// masked to a capsule, so it wraps without a visible seam.
    private func band(length: CGFloat, phase: CGFloat) -> some View {
        let stripLength = length * CGFloat(max(1, displayColors.count))
        return Group {
            if axis == .vertical {
                VStack(spacing: 0) {
                    gradientBlock(stripLength: stripLength)
                    gradientBlock(stripLength: stripLength)
                }
                .offset(y: (phase - 1) * stripLength)
                .frame(height: length, alignment: .top)
            } else {
                HStack(spacing: 0) {
                    gradientBlock(stripLength: stripLength)
                    gradientBlock(stripLength: stripLength)
                }
                .offset(x: (phase - 1) * stripLength)
                .frame(width: length, alignment: .leading)
            }
        }
        .mask(Capsule(style: .continuous))
    }

    private func gradientBlock(stripLength: CGFloat) -> some View {
        LinearGradient(
            gradient: stripGradient,
            startPoint: axis == .vertical ? .top : .leading,
            endPoint: axis == .vertical ? .bottom : .trailing
        )
        .frame(
            width: axis == .horizontal ? stripLength : nil,
            height: axis == .vertical ? stripLength : nil
        )
    }
}
