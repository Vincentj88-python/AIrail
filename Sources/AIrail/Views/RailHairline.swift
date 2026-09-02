import SwiftUI

/// The collapsed indicator: a single calm accent line with a soft matching
/// glow, gently breathing between two intensities. Deliberately barely-there —
/// one colour, never a rainbow. Runs vertically on the edge rail, horizontally
/// under the notch.
struct RailHairline: View {
    var reduceMotion: Bool
    var axis: Axis = .vertical

    /// A soft periwinkle that matches the overlay's accent; reads as a faint
    /// glow rather than a provider colour.
    private static let accent = Color(hex: 0x6E8BFF)
    private static let breathPeriod: Double = 4.5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion)) { context in
            let intensity = breath(at: context.date)
            ZStack {
                line(width: 5)
                    .blur(radius: 4)
                    .opacity(0.3 * intensity)
                line(width: 3)
                    .opacity(0.55 + 0.3 * intensity)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 0…1 ease in and out; a steady hold under Reduce Motion.
    private func breath(at date: Date) -> Double {
        guard !reduceMotion else { return 0.85 }
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.breathPeriod) / Self.breathPeriod
        return 0.5 - 0.5 * cos(t * 2 * .pi) // 0→1→0
    }

    private func line(width: CGFloat) -> some View {
        Capsule(style: .continuous)
            .fill(Self.accent)
            .frame(
                width: axis == .vertical ? width : nil,
                height: axis == .vertical ? nil : width
            )
    }
}
