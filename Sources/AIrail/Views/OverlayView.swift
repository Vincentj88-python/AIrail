import SwiftUI

/// The glass HUD for the selected provider. Layout mirrors
/// renders/03-stats-overlay.png: header, session ring, weekly numbers,
/// reset, sparkline, credits/spend footer.
struct OverlayView: View {
    @ObservedObject var manager: ProviderManager
    @ObservedObject var ui: RailUIState

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if let id = ui.selectedProviderId, let info = manager.providerInfo(for: id) {
                content(info: info, snapshot: manager.snapshot(for: id))
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
    }

    private func content(info: ProviderInfo, snapshot: UsageSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            header(info: info, snapshot: snapshot)
            sessionSection(info: info, snapshot: snapshot)
            sparklineSection(info: info, snapshot: snapshot)
            if snapshot?.credits != nil || snapshot?.spend != nil {
                Divider().overlay(Color.white.opacity(0.08))
                footer(snapshot: snapshot)
            }
        }
        .padding(24)
        .frame(width: 460, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.black.opacity(0.26))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1))
                )
        )
    }

    // MARK: Header

    private func header(info: ProviderInfo, snapshot: UsageSnapshot?) -> some View {
        HStack(spacing: 12) {
            LogoMark(
                color: info.color,
                symbolName: info.symbolName,
                brandIconPath: info.brandIconPath,
                percent: nil,
                size: 36
            )
            Text(info.displayName)
                .font(.system(size: 26, weight: .semibold))
            if let plan = snapshot?.plan {
                pill(text: "\(plan) plan", tint: info.color)
            }
            if let status = snapshot?.status {
                pill(text: status.rawValue, tint: .gray)
            }
            Spacer()
            Menu {
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                Divider()
                Button("Quit AIrail") {
                    NSApp.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func pill(text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.18)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.3)))
            .foregroundStyle(tint == .gray ? Color.secondary : tint)
    }

    // MARK: Session

    private func sessionSection(info: ProviderInfo, snapshot: UsageSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionCaption("SESSION USAGE")
            HStack(spacing: 26) {
                sessionRing(info: info, snapshot: snapshot)
                VStack(alignment: .leading, spacing: 9) {
                    if let used = snapshot?.weeklyUsed, let limit = snapshot?.weeklyLimit {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(Int(used).formatted())
                                .font(.system(size: 27, weight: .semibold))
                                .monospacedDigit()
                            Text("/ \(Int(limit).formatted())")
                                .font(.system(size: 21))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Text("weekly requests")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    if let resetsAt = snapshot?.resetsAt {
                        Text(UsageFormatting.resetString(resetsAt))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    if let lastUpdated = snapshot?.lastUpdated {
                        HStack(spacing: 6) {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                            Text("Last updated ")
                                .foregroundStyle(.secondary)
                                + Text(UsageFormatting.lastUpdatedString(lastUpdated))
                                .fontWeight(.medium)
                        }
                        .font(.subheadline)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Weekly usage")
                .accessibilityValue(weeklyAccessibilityValue(snapshot: snapshot))
            }
        }
    }

    private func sessionRing(info: ProviderInfo, snapshot: UsageSnapshot?) -> some View {
        let percent = snapshot?.sessionPercent.map(UsageSnapshot.clampPercent)
        return ZStack {
            Circle()
                .stroke(info.color.opacity(0.18), lineWidth: 9)
            Circle()
                .trim(from: 0, to: (percent ?? 0) / 100)
                .stroke(info.color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: percent)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(percent.map { "\(Int($0.rounded()))" } ?? "—")
                    .font(.system(size: 42, weight: .semibold))
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 138, height: 138)
        .padding(5)
        .accessibilityElement()
        .accessibilityLabel("Session usage")
        .accessibilityValue(percent.map { "\(Int($0.rounded())) percent" } ?? "unknown")
    }

    // MARK: Sparkline

    private func sparklineSection(info: ProviderInfo, snapshot: UsageSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionCaption("USAGE (7 DAYS)")
            if let snapshot, snapshot.weeklyHistory.count == 7 {
                Sparkline(
                    values: snapshot.weeklyHistory,
                    dates: snapshot.historyDates,
                    color: info.color
                )
            } else {
                Text("No history yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Footer

    private func footer(snapshot: UsageSnapshot?) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if let credits = snapshot?.credits {
                VStack(alignment: .leading, spacing: 6) {
                    sectionCaption("CREDITS")
                    HStack(spacing: 8) {
                        Image(systemName: "cylinder.split.1x2")
                            .foregroundStyle(.secondary)
                        Text(Int(credits).formatted())
                            .font(.system(size: 23, weight: .semibold))
                            .monospacedDigit()
                    }
                    Text("remaining")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Credits")
                .accessibilityValue("\(Int(credits).formatted()) remaining")
            }
            if let spend = snapshot?.spend {
                if snapshot?.credits != nil {
                    Divider()
                        .frame(height: 52)
                        .overlay(Color.white.opacity(0.08))
                        .padding(.trailing, 20)
                }
                VStack(alignment: .leading, spacing: 6) {
                    sectionCaption("SPEND (\(UsageFormatting.currentMonthAbbreviation()))")
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(.secondary)
                        Text(String(format: "$%.2f", spend))
                            .font(.system(size: 23, weight: .semibold))
                            .monospacedDigit()
                    }
                    if let cap = snapshot?.spendCap {
                        Text(String(format: "of $%.2f limit", cap))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Spend this month")
                .accessibilityValue(spendAccessibilityValue(snapshot: snapshot, spend: spend))
            }
        }
    }

    // MARK: Helpers

    private func sectionCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .kerning(0.8)
            .foregroundStyle(.secondary)
    }

    private func weeklyAccessibilityValue(snapshot: UsageSnapshot?) -> String {
        guard let used = snapshot?.weeklyUsed, let limit = snapshot?.weeklyLimit else {
            return "unknown"
        }
        return "\(Int(used)) of \(Int(limit)) weekly requests"
    }

    private func spendAccessibilityValue(snapshot: UsageSnapshot?, spend: Double) -> String {
        if let cap = snapshot?.spendCap {
            return String(format: "$%.2f of $%.2f limit", spend, cap)
        }
        return String(format: "$%.2f", spend)
    }
}
