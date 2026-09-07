import SwiftUI

/// 7-day usage line: gradient area fill, round-capped line, a dot per day,
/// and day labels underneath with today tinted in the provider color.
struct Sparkline: View {
    let values: [Double]
    let dates: [Date]
    let color: Color
    /// Index of the day under the pointer, drawn with a marker line and a bigger dot.
    var highlighted: Int? = nil
    /// The daily average, drawn as a dashed line across the days like Screen Time's.
    var average: Double? = nil

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let points = normalizedPoints(in: geo.size)
                ZStack {
                    gridlines(points: points, height: geo.size.height)
                    if let average, let y = yPosition(for: average, in: geo.size) {
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                        .stroke(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    areaPath(points: points, height: geo.size.height)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.28), color.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    linePath(points: points)
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    if let highlighted, points.indices.contains(highlighted) {
                        Path { path in
                            path.move(to: CGPoint(x: points[highlighted].x, y: 0))
                            path.addLine(to: CGPoint(x: points[highlighted].x, y: geo.size.height))
                        }
                        .stroke(color.opacity(0.5), lineWidth: 1)
                    }
                    ForEach(points.indices, id: \.self) { index in
                        let isHighlighted = index == highlighted
                        Circle()
                            .fill(isHighlighted ? color : Color.black.opacity(0.8))
                            .overlay(Circle().strokeBorder(color, lineWidth: 1.5))
                            .frame(width: isHighlighted ? 9 : 7, height: isHighlighted ? 9 : 7)
                            .position(points[index])
                    }
                }
            }
            .frame(height: 104)
            labels
        }
        .accessibilityElement()
        .accessibilityLabel("Seven day usage")
        .accessibilityValue(accessibilitySummary)
    }

    private var labels: some View {
        HStack(spacing: 0) {
            ForEach(dates.indices, id: \.self) { index in
                let isToday = index == dates.count - 1
                VStack(spacing: 2) {
                    Text(dates[index].formatted(.dateTime.day()))
                        .font(.caption.weight(isToday ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(isToday ? color : .primary)
                    Text(dates[index].formatted(.dateTime.weekday(.abbreviated)))
                        .font(.caption2)
                        .foregroundStyle(isToday ? color.opacity(0.9) : .secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let columnWidth = size.width / CGFloat(values.count)
        return values.enumerated().map { index, value in
            CGPoint(x: columnWidth * (CGFloat(index) + 0.5), y: yPosition(for: value, in: size) ?? size.height)
        }
    }

    /// The same vertical scale the points use, for any value on it.
    private func yPosition(for value: Double, in size: CGSize) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let span = max(high - low, 0.0001)
        let topInset: CGFloat = 8
        let bottomInset: CGFloat = 8
        let usableHeight = size.height - topInset - bottomInset
        let normalized = min(max((value - low) / span, 0), 1)
        return size.height - bottomInset - usableHeight * CGFloat(normalized)
    }

    private func linePath(points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            points.dropFirst().forEach { path.addLine(to: $0) }
        }
    }

    private func areaPath(points: [CGPoint], height: CGFloat) -> Path {
        Path { path in
            guard let first = points.first, let last = points.last else { return }
            path.move(to: CGPoint(x: first.x, y: height))
            path.addLine(to: first)
            points.dropFirst().forEach { path.addLine(to: $0) }
            path.addLine(to: CGPoint(x: last.x, y: height))
            path.closeSubpath()
        }
    }

    private func gridlines(points: [CGPoint], height: CGFloat) -> some View {
        Path { path in
            for point in points {
                path.move(to: CGPoint(x: point.x, y: 0))
                path.addLine(to: CGPoint(x: point.x, y: height))
            }
        }
        .stroke(
            Color.white.opacity(0.07),
            style: StrokeStyle(lineWidth: 1, dash: [2, 4])
        )
    }

    private var accessibilitySummary: String {
        zip(dates, values)
            .map { "\($0.formatted(.dateTime.weekday(.abbreviated))): \(Int($1))" }
            .joined(separator: ", ")
    }
}
