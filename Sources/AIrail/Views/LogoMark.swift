import SwiftUI

/// Circular provider mark: usage ring at the rim, glass disc, SF Symbol.
/// Original marks only — no brand logo assets.
struct LogoMark: View {
    let color: Color
    let symbolName: String
    let percent: Double?
    var size: CGFloat = 44
    var isSelected = false

    private var ringWidth: CGFloat { max(2.5, size * 0.062) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: ringWidth)
                .padding(ringWidth / 2)
            if let percent {
                Circle()
                    .trim(from: 0, to: UsageSnapshot.clampPercent(percent) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(ringWidth / 2)
            }
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().fill(Color.black.opacity(0.28)))
                .padding(ringWidth * 2)
            Image(systemName: symbolName)
                .font(.system(size: size * 0.34, weight: .medium))
                .foregroundStyle(color)
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
}
