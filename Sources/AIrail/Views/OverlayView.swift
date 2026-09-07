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
            if let notice = notice(info: info, snapshot: snapshot) {
                notice
            }
            sessionSection(info: info, snapshot: snapshot)
            if let meters = snapshot?.detail.meters, !meters.isEmpty {
                MetersList(meters: meters, color: info.color)
            }
            UsageChartSection(
                detail: snapshot?.detail ?? UsageDetail(),
                color: info.color,
                sessionWindow: sessionWindow(snapshot: snapshot)
            )
            if let detail = snapshot?.detail, detail.hasActivity {
                if !detail.byModel.isEmpty || !detail.byProject.isEmpty {
                    UsageBreakdown(detail: detail, color: info.color)
                }
                ActivityLine(week: detail.week, tools: detail.topTools)
                // Only a live account with nothing priced in dollars already:
                // a demo profile has nothing to value, and a keyed platform's
                // reported spend or Cursor's per-request cents beat an estimate
                // of the same. A subscription tool keeps the line even with a
                // spend figure — Claude's extra usage is an overage on top of
                // the plan, not a price on the plan's own tokens.
                if let snapshot, snapshot.status != .demo, detail.week.cost == 0,
                   snapshot.spend == nil || info.kind == .tool,
                   let value = ModelPricing.estimate(detail.week) {
                    valueLine(value, plan: snapshot.plan)
                }
            }
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
                StatusPill(status: status)
            }
            Spacer()
            Menu {
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                Button(UpdateChecker.menuTitle(for: ui.availableUpdate)) {
                    if let release = ui.availableUpdate {
                        UpdateChecker.show(release)
                    } else {
                        UpdateChecker.checkForUpdates()
                    }
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

    // MARK: Notice

    /// One line under the header when the numbers need a caveat: demo data
    /// with a way to connect, or why a connected account isn't reading.
    private func notice(info: ProviderInfo, snapshot: UsageSnapshot?) -> AnyView? {
        guard let snapshot else { return nil }
        switch snapshot.status {
        case .demo:
            return AnyView(
                HStack(spacing: 8) {
                    Text("Demo data.")
                        .foregroundStyle(.secondary)
                    Button("Connect \(info.displayName)…") {
                        ui.settingsTab = .accounts
                        NSApp.activate(ignoringOtherApps: true)
                        openSettings()
                    }
                    .buttonStyle(.link)
                }
                .font(.subheadline)
            )
        case .stale, .error:
            guard let error = manager.lastErrors[info.id] else { return nil }
            return AnyView(
                VStack(alignment: .leading, spacing: 4) {
                    Label(error.errorDescription ?? error.shortDescription, systemImage: error.symbolName)
                        .foregroundStyle(snapshot.status.tint)
                    if let reset = snapshot.expiredResetAt {
                        // The numbers for that window are gone from the card;
                        // say why, rather than leave a blank ring unexplained.
                        Text("The \(snapshot.expiredWindowLabel ?? "usage") window reset \(UsageFormatting.weekdayTime(reset)) — nothing has been read since.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            )
        case .ok:
            return nil
        }
    }

    // MARK: Session

    private func sessionSection(info: ProviderInfo, snapshot: UsageSnapshot?) -> some View {
        let hasSession = snapshot?.sessionPercent != nil
        let period = snapshot?.periodLabel ?? "weekly"
        return VStack(alignment: .leading, spacing: 14) {
            sectionCaption(hasSession ? "SESSION USAGE" : "\(period.uppercased()) USAGE")
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
                        Text("\(period) \(snapshot?.unitLabel ?? "requests")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    } else if hasSession, let weekly = snapshot?.weeklyPercent {
                        // Providers that report the longer window as a percent only.
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("\(Int(weekly.rounded()))")
                                .font(.system(size: 27, weight: .semibold))
                                .monospacedDigit()
                                .contentTransition(.numericText(value: weekly))
                                .animation(.default, value: weekly)
                            Text("%")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Text("of \(period) limit")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        if hasSession, let resetsAt = snapshot?.resetsAt {
                            resetText("session", resetsAt)
                        }
                        if let weeklyResetsAt = snapshot?.weeklyResetsAt {
                            resetText(period, weeklyResetsAt)
                        } else if !hasSession, let resetsAt = snapshot?.resetsAt {
                            resetText(nil, resetsAt)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    if let projection = manager.projection(for: info.id) {
                        burnRate(projection, info: info)
                    } else if let snapshot, snapshot.status == .ok, let pace = snapshot.pace() {
                        paceLine(pace, info: info)
                    }
                    if let lastUpdated = snapshot?.lastUpdated {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(snapshot?.status.tint ?? .gray)
                                .frame(width: 6, height: 6)
                            Text("Last updated ")
                                .foregroundStyle(.secondary)
                                + Text(UsageFormatting.lastUpdatedString(lastUpdated))
                                .fontWeight(.medium)
                        }
                        .font(.subheadline)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(period.capitalized) usage")
                .accessibilityValue(weeklyAccessibilityValue(snapshot: snapshot))
            }
        }
    }

    /// "session resets in 2 hr, 41 min", ticking by itself while the reset is
    /// under a day away; "weekly resets Mon 9:00 AM" beyond that.
    private func resetText(_ window: String?, _ date: Date) -> Text {
        let prefix = window.map { $0 + " " } ?? ""
        let untilReset = date.timeIntervalSinceNow
        if untilReset > 0, untilReset < 24 * 3600 {
            return Text(prefix + "resets in ") + Text(date, style: .relative)
        }
        return Text(prefix + UsageFormatting.resetString(date))
    }

    /// "≈ 2h 24m to limit at this pace", or reassurance that the window resets first.
    private func burnRate(_ projection: UsageProjection, info: ProviderInfo) -> some View {
        let resetsFirst = projection.resetsFirst
        return HStack(spacing: 6) {
            Image(systemName: resetsFirst ? "checkmark.circle" : "gauge.with.dots.needle.67percent")
                .foregroundStyle(resetsFirst ? Color.green : info.color)
            Text(resetsFirst
                 ? "On track — \(projection.basis) resets first"
                 : "≈ \(UsageFormatting.duration(hours: projection.hoursToLimit)) to limit at this pace")
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(.top, 2)
        .accessibilityLabel(resetsFirst
            ? "On track, the \(projection.basis) window resets before the limit"
            : "About \(UsageFormatting.duration(hours: projection.hoursToLimit)) to the limit at the current pace")
    }

    /// "12 pts above an even pace" — where the figure sits against the time
    /// elapsed in its window. Two live numbers and the clock, nothing estimated.
    private func paceLine(_ pace: UsagePace, info: ProviderInfo) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .foregroundStyle(pace.delta >= 10 ? info.color : Color.secondary)
            Text(pace.summary)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(.top, 2)
        .help("\(Int((pace.elapsed * 100).rounded()))% of the \(pace.basis) window has passed; an even pace would have used that share of the limit.")
        .accessibilityLabel(pace.summary)
    }

    private func sessionRing(info: ProviderInfo, snapshot: UsageSnapshot?) -> some View {
        let percent = snapshot?.ringPercent
        let label = snapshot?.sessionPercent != nil ? "Session usage" : "\(snapshot?.periodLabel ?? "Weekly") usage"
        // Once a minute, so the elapsed arc and the "left" caption keep time
        // between refreshes.
        return TimelineView(.periodic(from: .now, by: 60)) { context in
            let pace = snapshot?.status == .ok ? snapshot?.pace(now: context.date) : nil
            ZStack {
                Circle()
                    .stroke(info.color.opacity(0.18), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: (percent ?? 0) / 100)
                    .stroke(info.color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: percent)
                // Time elapsed in the window, as a thinner arc just inside the
                // ring: a fill that runs ahead of it is faster than an even pace.
                if let pace {
                    Circle()
                        .trim(from: 0, to: pace.elapsed)
                        .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(11)
                }
                VStack(spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(percent.map { "\(Int($0.rounded()))" } ?? "—")
                            .font(.system(size: 42, weight: .semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: percent ?? 0))
                            .animation(.default, value: percent)
                        Text("%")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if let pace {
                        Text("\(UsageFormatting.duration(hours: pace.remaining / 3600)) left")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(width: 138, height: 138)
        .padding(5)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(percent.map { "\(Int($0.rounded())) percent" } ?? "unknown")
    }

    /// "≈ $340 of API-priced tokens this week" — what a subscription's usage
    /// would have cost pay-as-you-go. An estimate, always labelled as one.
    private func valueLine(_ dollars: Double, plan: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.stars.inverse")
                .foregroundStyle(.secondary)
            Text("≈ ")
                .foregroundStyle(.secondary)
                + Text(UsageFormatting.dollars(dollars))
                .fontWeight(.semibold)
                + Text(" of API-priced tokens this week")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .help("Estimated pay-as-you-go API cost of this week's tokens, at public model prices. An estimate, not a bill.")
        .accessibilityLabel("Estimated API-equivalent value this week: \(UsageFormatting.dollars(dollars))")
    }

    // MARK: Chart

    /// The rolling session window the ring measures, ending at the reported
    /// reset time; its length comes from the provider, not a constant.
    private func sessionWindow(snapshot: UsageSnapshot?) -> DateInterval? {
        snapshot?.sessionWindow
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
                        Text(UsageFormatting.credits(credits, currency: snapshot?.creditsCurrency))
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
                .accessibilityValue("\(UsageFormatting.credits(credits, currency: snapshot?.creditsCurrency)) remaining")
            }
            if let spend = snapshot?.spend {
                let period = snapshot?.spendPeriod ?? .month
                if snapshot?.credits != nil {
                    Divider()
                        .frame(height: 52)
                        .overlay(Color.white.opacity(0.08))
                        .padding(.trailing, 20)
                }
                VStack(alignment: .leading, spacing: 6) {
                    sectionCaption(UsageFormatting.spendCaption(period))
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(.secondary)
                        Text(UsageFormatting.dollars(spend))
                            .font(.system(size: 23, weight: .semibold))
                            .monospacedDigit()
                    }
                    if let cap = snapshot?.spendCap {
                        Text("of \(UsageFormatting.dollars(cap)) limit")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(UsageFormatting.spendLabel(period))
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
        let period = snapshot?.periodLabel ?? "weekly"
        if let used = snapshot?.weeklyUsed, let limit = snapshot?.weeklyLimit {
            return "\(Int(used)) of \(Int(limit)) \(period) \(snapshot?.unitLabel ?? "requests")"
        }
        if let percent = snapshot?.weeklyPercent {
            return "\(Int(percent.rounded())) percent of \(period) limit"
        }
        return "unknown"
    }

    private func spendAccessibilityValue(snapshot: UsageSnapshot?, spend: Double) -> String {
        if let cap = snapshot?.spendCap {
            return "\(UsageFormatting.dollars(spend)) of \(UsageFormatting.dollars(cap)) limit"
        }
        return UsageFormatting.dollars(spend)
    }
}
