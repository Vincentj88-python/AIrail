import SwiftUI

/// The overlay's chart, modelled on System Settings › Battery: a segmented
/// `24 Hours | 7 Days` switch, hover for the numbers behind a bar or day, and
/// (for providers with a session window) the current 5-hour window shaded.
struct UsageChartSection: View {
    enum ChartRange: String, CaseIterable, Identifiable {
        case day, week
        var id: String { rawValue }
        var label: String { self == .day ? "24 Hours" : "7 Days" }
    }

    let detail: UsageDetail
    let color: Color
    /// The provider's current rolling session window, when it has one.
    let sessionWindow: DateInterval?

    @AppStorage("overlayChartRange") private var storedRange = ChartRange.day.rawValue
    @State private var hoverIndex: Int?

    private var range: ChartRange {
        ChartRange(rawValue: storedRange) ?? .day
    }

    private var hours: [UsageBucket] { detail.hours }
    private var days: [UsageBucket] { detail.days }
    private var hasHourly: Bool { !hours.isEmpty }
    private var hasDaily: Bool { !days.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                header
                Spacer()
                if hasHourly && hasDaily {
                    Picker("Range", selection: rangeBinding) {
                        ForEach(ChartRange.allCases) { range in
                            Text(range.label).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .labelsHidden()
                    .frame(width: 160)
                }
            }
            chart
        }
    }

    /// Screen Time's header over the chart: a caption naming the range, the
    /// hero figure for it, and for the week how it compares with the week
    /// before. Plain "USAGE" until there is any history.
    @ViewBuilder
    private var header: some View {
        if !hasHourly && !hasDaily {
            Text("USAGE")
                .font(.caption.weight(.medium))
                .kerning(0.8)
                .foregroundStyle(.secondary)
        } else {
            let showingDay = range == .day && hasHourly
            VStack(alignment: .leading, spacing: 2) {
                Text(showingDay ? "LAST 24 HOURS" : "DAILY AVERAGE")
                    .font(.caption.weight(.medium))
                    .kerning(0.8)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(showingDay ? Self.figure(hours.reduce(0) { $0 + $1.usage.tokens.total }) : Self.figure(detail.week.tokens.total / Double(max(days.count, 1))))
                        .font(.system(size: 20, weight: .semibold))
                        .monospacedDigit()
                    if !showingDay, let delta = detail.weekOverWeek {
                        Label("\(abs(Int(delta.rounded())))% from last week", systemImage: delta >= 0 ? "arrow.up" : "arrow.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Tokens over the last seven days against the seven before them.")
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    static func figure(_ tokens: Double) -> String {
        UsageFormatting.compactTokens(tokens) + " tokens"
    }

    private var rangeBinding: Binding<ChartRange> {
        Binding(
            get: { range },
            set: { storedRange = $0.rawValue; hoverIndex = nil }
        )
    }

    @ViewBuilder
    private var chart: some View {
        if range == .day, hasHourly {
            hourlyChart
        } else if hasDaily {
            dailyChart
        } else {
            Text("No history yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Hourly

    private var hourlyChart: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                HourlyBars(
                    buckets: hours,
                    color: color,
                    sessionWindow: sessionWindow,
                    highlighted: hoverIndex
                )
                .frame(height: 104)
                .overlay(hoverTracker(count: hours.count))
                callout(for: hoverIndex.flatMap { hours.indices.contains($0) ? hours[$0] : nil }, count: hours.count, style: .hour)
            }
            hourLabels
        }
        .accessibilityElement()
        .accessibilityLabel("Usage over the last 24 hours")
        .accessibilityValue(hourlyAccessibilitySummary)
    }

    private var hourLabels: some View {
        HStack(spacing: 0) {
            ForEach(hours.indices, id: \.self) { index in
                // Every sixth hour, written the way the Battery pane's axis is:
                // "12 AM · 6 AM · 12 PM" on a 12-hour clock, "00 · 06 · 12" on a 24-hour one.
                let hour = Calendar.current.component(.hour, from: hours[index].start)
                Text(hour % 6 == 0 ? Self.axisHour(hours[index].start) : "")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Daily

    private var dailyChart: some View {
        ZStack(alignment: .top) {
            Sparkline(
                values: days.map { $0.usage.tokens.total }, dates: days.map(\.start), color: color,
                highlighted: hoverIndex, average: detail.week.tokens.total / Double(max(days.count, 1))
            )
                .overlay(alignment: .top) {
                    hoverTracker(count: days.count).frame(height: 104)
                }
            callout(for: hoverIndex.flatMap { days.indices.contains($0) ? days[$0] : nil }, count: days.count, style: .day)
        }
    }

    // MARK: Hover

    private func hoverTracker(count: Int) -> some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let index = Int(point.x / geo.size.width * CGFloat(count))
                        hoverIndex = min(max(index, 0), count - 1)
                    case .ended:
                        hoverIndex = nil
                    }
                }
        }
    }

    private enum CalloutStyle { case hour, day }

    @ViewBuilder
    private func callout(for bucket: UsageBucket?, count: Int, style: CalloutStyle) -> some View {
        if let bucket, let index = hoverIndex {
            GeometryReader { geo in
                let column = geo.size.width / CGFloat(count)
                let x = column * (CGFloat(index) + 0.5)
                ChartCallout(bucket: bucket, style: style == .hour ? .hour : .day)
                    .fixedSize()
                    .background(GeometryReader { calloutGeo in
                        Color.clear.preference(key: CalloutWidthKey.self, value: calloutGeo.size.width)
                    })
                    .modifier(ClampedCalloutPosition(x: x, width: geo.size.width))
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private var hourlyAccessibilitySummary: String {
        hours.map { bucket in
            "\(Self.axisHour(bucket.start)): \(UsageFormatting.compactTokens(bucket.usage.tokens.total)) tokens"
        }
        .joined(separator: ", ")
    }

    static func axisHour(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
    }
}

// MARK: - Callout

private struct CalloutWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Keeps the callout centred on its column but inside the chart's edges.
private struct ClampedCalloutPosition: ViewModifier {
    let x: CGFloat
    let width: CGFloat
    @State private var calloutWidth: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(CalloutWidthKey.self) { calloutWidth = $0 }
            .position(x: min(max(x, calloutWidth / 2), width - calloutWidth / 2), y: 26)
    }
}

struct ChartCallout: View {
    enum Style { case hour, day }

    let bucket: UsageBucket
    let style: Style

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if bucket.usage.tokens.total > 0 {
                Text(split)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        )
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
    }

    /// "Mon, 9:00 – 10:00 AM" / "Mon, 09:00 – 10:00", and "Mon, Sep 1" /
    /// "Mon 1 Sept" — the interval and the day in the user's own notation.
    private var title: String {
        switch style {
        case .hour:
            let end = bucket.start.addingTimeInterval(3600)
            return (bucket.start..<end).formatted(Date.IntervalFormatStyle().weekday(.abbreviated).hour().minute())
        case .day:
            return bucket.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
    }

    private var summary: String {
        let usage = bucket.usage
        var parts = ["\(UsageFormatting.compactTokens(usage.tokens.total)) tokens"]
        if usage.messages > 0 { parts.append("\(usage.messages) requests") }
        if usage.cost > 0 { parts.append(UsageFormatting.dollars(usage.cost)) }
        return parts.joined(separator: " · ")
    }

    private var split: String {
        let t = bucket.usage.tokens
        var parts = [
            "in \(UsageFormatting.compactTokens(t.input))",
            "out \(UsageFormatting.compactTokens(t.output))",
        ]
        let cache = t.cacheRead + t.cacheWrite
        if cache > 0 { parts.append("cache \(UsageFormatting.compactTokens(cache))") }
        if bucket.usage.thinking > 0 { parts.append("thinking \(UsageFormatting.compactTokens(bucket.usage.thinking))") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Hourly bars

struct HourlyBars: View {
    let buckets: [UsageBucket]
    let color: Color
    let sessionWindow: DateInterval?
    var highlighted: Int? = nil

    var body: some View {
        GeometryReader { geo in
            let count = max(1, buckets.count)
            let column = geo.size.width / CGFloat(count)
            let peak = max(buckets.map { $0.usage.tokens.total }.max() ?? 0, 1)
            ZStack(alignment: .bottomLeading) {
                if let window = sessionWindow, let shading = shadingFrame(for: window, column: column, width: geo.size.width) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(color.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(color.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        )
                        .overlay(alignment: .topTrailing) {
                            if shading.width > 44 {
                                Text("session")
                                    .font(.caption2)
                                    .foregroundStyle(color.opacity(0.8))
                                    .padding(.trailing, 5)
                                    .padding(.top, 3)
                            }
                        }
                        .frame(width: shading.width, height: geo.size.height)
                        .offset(x: shading.minX)
                }
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(buckets.indices, id: \.self) { index in
                        let value = buckets[index].usage.tokens.total
                        let fraction = CGFloat(value / peak)
                        let height = value > 0 ? max(3, (geo.size.height - 14) * fraction) : 2
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(barColor(index: index, empty: value == 0))
                            .frame(width: max(2, column - 3), height: height)
                            .frame(maxWidth: .infinity, alignment: .bottom)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
        }
    }

    private func barColor(index: Int, empty: Bool) -> Color {
        if empty { return Color.white.opacity(0.08) }
        if let highlighted { return index == highlighted ? color : color.opacity(0.55) }
        return color.opacity(0.85)
    }

    /// Where the window falls across the columns; nil when it is entirely
    /// outside the chart. Its future part is clipped at the right edge.
    private func shadingFrame(for window: DateInterval, column: CGFloat, width: CGFloat) -> CGRect? {
        guard let first = buckets.first?.start, let last = buckets.last?.start else { return nil }
        let chartStart = first
        let chartEnd = last.addingTimeInterval(3600)
        let start = max(window.start, chartStart)
        let end = min(window.end, chartEnd)
        guard end > start else { return nil }
        let scale = width / chartEnd.timeIntervalSince(chartStart)
        let minX = start.timeIntervalSince(chartStart) * scale
        let maxX = end.timeIntervalSince(chartStart) * scale
        return CGRect(x: minX, y: 0, width: maxX - minX, height: 0)
    }
}

// MARK: - Breakdown lists

/// Screen Time-style "by model" / "by project" columns: name, share bar, tokens.
struct UsageBreakdown: View {
    let detail: UsageDetail
    let color: Color
    var maxRows = 3

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            if !detail.byModel.isEmpty {
                column(title: "BY MODEL", shares: detail.byModel) { UsageFormatting.modelDisplayName($0.name) }
            }
            if !detail.byProject.isEmpty {
                column(title: "BY PROJECT", shares: detail.byProject) { $0.name }
            }
        }
    }

    private func column(title: String, shares: [UsageShare], name: @escaping (UsageShare) -> String) -> some View {
        let top = shares.prefix(maxRows)
        let peak = max(top.first?.tokens ?? 1, 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .kerning(0.8)
                .foregroundStyle(.secondary)
            ForEach(top) { share in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(name(share))
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(UsageFormatting.compactTokens(share.tokens))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        // Quiet money beside the tokens: the provider's own
                        // figure plain, an estimate with "≈"; nothing under a dollar.
                        if let cost = share.cost, cost >= 1 {
                            Text((share.costIsEstimate ? "≈ " : "") + UsageFormatting.dollars(cost))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule().fill(color.opacity(0.8))
                                .frame(width: max(3, geo.size.width * CGFloat(share.tokens / peak)))
                        }
                    }
                    .frame(height: 4)
                }
                .help(help(for: share, name: name(share)))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(name(share))
                .accessibilityValue(accessibilityValue(for: share))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension UsageBreakdown {
    fileprivate func help(for share: UsageShare, name: String) -> String {
        var text = "\(name): \(Int(share.tokens).formatted()) tokens"
        if let cost = share.cost, cost >= 1 {
            text += share.costIsEstimate
                ? " · ≈ \(UsageFormatting.dollars(cost)) at public API prices (an estimate, not a bill)"
                : " · \(UsageFormatting.dollars(cost)) by the provider's own accounting"
        }
        return text
    }

    fileprivate func accessibilityValue(for share: UsageShare) -> String {
        var text = "\(UsageFormatting.compactTokens(share.tokens)) tokens"
        if let cost = share.cost, cost >= 1 {
            text += share.costIsEstimate ? ", about \(UsageFormatting.dollars(cost)) estimated" : ", \(UsageFormatting.dollars(cost))"
        }
        return text
    }
}

/// One line of week totals: requests, sessions, thinking share, top tools.
struct ActivityLine: View {
    let week: UsageAggregate
    let tools: [(name: String, count: Int)]

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Activity this week")
            .accessibilityValue(text)
    }

    private var text: String {
        var parts: [String] = []
        if week.messages > 0 { parts.append("\(week.messages.formatted()) requests") }
        if !week.sessions.isEmpty { parts.append("\(week.sessions.count) sessions") }
        if let share = week.thinkingShare, share > 0 { parts.append("\(Int((share * 100).rounded()))% thinking") }
        for tool in tools.prefix(3) { parts.append("\(tool.name) \(tool.count.formatted())") }
        return parts.joined(separator: " · ")
    }
}

/// A provider's several meters (Copilot's premium / chat / completions,
/// Cursor's included / auto / API), each a labelled bar.
struct MetersList: View {
    let meters: [UsageMeter]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(meters) { meter in
                HStack(spacing: 10) {
                    Text(meter.name)
                        .font(.caption)
                        .frame(width: 118, alignment: .leading)
                        .lineLimit(1)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            if let percent = meter.percent {
                                Capsule().fill(color.opacity(0.8))
                                    .frame(width: max(3, geo.size.width * CGFloat(UsageSnapshot.clampPercent(percent) / 100)))
                            }
                        }
                    }
                    .frame(height: 5)
                    Text(value(for: meter))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .trailing)
                        .lineLimit(1)
                }
                .help(meter.note ?? "\(meter.name): \(value(for: meter))")
                .accessibilityElement(children: .combine)
                .accessibilityLabel(meter.name)
                .accessibilityValue(value(for: meter))
            }
        }
    }

    private func value(for meter: UsageMeter) -> String {
        if let used = meter.used, let limit = meter.limit {
            return "\(Int(used).formatted()) / \(Int(limit).formatted())"
        }
        if let percent = meter.percent {
            return "\(Int(percent.rounded()))%"
        }
        return meter.note ?? "—"
    }
}
