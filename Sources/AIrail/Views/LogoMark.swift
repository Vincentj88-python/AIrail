import SwiftUI

/// Circular provider mark: usage ring at the rim, glass disc, SF Symbol.
/// Original marks only — no brand logo assets.
struct LogoMark: View {
    let color: Color
    let symbolName: String
    var brandIconPath: String? = nil
    let percent: Double?
    var size: CGFloat = 44
    var isSelected = false
    /// True on the black notch/island, where the frosted disc and faint track
    /// go muddy; uses a cleaner dark seat and a track that reads on black.
    var onDark = false
    /// How much of the window has elapsed (0...1): drawn as a small tick on
    /// the ring, so a fill ahead of the tick reads as faster than an even pace.
    var elapsed: Double? = nil

    private var ringWidth: CGFloat { max(2.5, size * (onDark ? 0.07 : 0.062)) }

    var body: some View {
        ZStack {
            // A neutral base ring guarantees the gauge reads as a full circle,
            // so a partial fill looks like usage, not a spinner.
            Circle()
                .stroke(Color.white.opacity(onDark ? 0.12 : 0.06), lineWidth: ringWidth)
                .padding(ringWidth / 2)
            Circle()
                .stroke(color.opacity(onDark ? 0.32 : 0.22), lineWidth: ringWidth)
                .padding(ringWidth / 2)
            if let percent {
                Circle()
                    .trim(from: 0, to: UsageSnapshot.clampPercent(percent) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(ringWidth / 2)
            }
            if let elapsed {
                Capsule()
                    .fill(Color.white.opacity(onDark ? 0.7 : 0.55))
                    .frame(width: 2, height: ringWidth + 2)
                    .offset(y: -(size / 2 - ringWidth))
                    .rotationEffect(.degrees(min(max(elapsed, 0), 1) * 360))
            }
            disc
                .padding(ringWidth * 2)
            if let brandIconPath {
                SVGPathShape(pathData: brandIconPath)
                    .fill(color)
                    .frame(width: size * 0.44, height: size * 0.44)
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: size * 0.34, weight: onDark ? .semibold : .medium))
                    .foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if isSelected {
                Circle()
                    .strokeBorder(color.opacity(0.85), lineWidth: 1.5)
                    .padding(-3.5)
            }
        }
        .shadow(color: isSelected ? color.opacity(0.55) : .clear, radius: 7)
        .animation(.easeInOut(duration: 0.3), value: percent)
    }

    /// The disc the glyph sits on: frosted glass on the rail/overlay, a clean
    /// dark chip lifted just off black on the notch island.
    @ViewBuilder
    private var disc: some View {
        if onDark {
            Circle()
                .fill(Color(white: 0.13))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
        } else {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().fill(Color.black.opacity(0.28)))
        }
    }
}
