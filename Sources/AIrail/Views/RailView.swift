import SwiftUI

struct RailView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var manager: ProviderManager
    @ObservedObject var ui: RailUIState
    var onSelect: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    /// Opening: a bouncy genie-style spring with visible overshoot.
    private var expandAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: 0.42, dampingFraction: 0.66)
    }

    /// Closing: quicker and critically damped — the rail tucks away.
    private var collapseAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.15)
            : .spring(response: 0.28, dampingFraction: 0.9)
    }

    private var edge: Alignment {
        settings.railSide == .left ? .leading : .trailing
    }

    private var edgePadding: Edge.Set {
        settings.railSide == .left ? .leading : .trailing
    }

    private var edgeAnchor: UnitPoint {
        settings.railSide == .left ? UnitPoint(x: 0, y: 0.5) : UnitPoint(x: 1, y: 0.5)
    }

    var body: some View {
        ZStack(alignment: edge) {
            Color.clear
            if ui.isExpanded {
                ExpandedRailContent(
                    settings: settings,
                    manager: manager,
                    ui: ui,
                    reduceMotion: reduceMotion,
                    onSelect: onSelect
                )
                .padding(edgePadding, 6)
                .transition(railTransition)
            } else {
                hairline
                    .padding(edgePadding, 4)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge)
        .animation(ui.isExpanded ? expandAnimation : collapseAnimation, value: ui.isExpanded)
        .onAppear {
            if let tab = LaunchOptions.settingsTab {
                ui.settingsTab = tab
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
        }
        .contextMenu {
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
        }
    }

    /// The card grows out of the screen edge and tucks back into it.
    private var railTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: 0.55, anchor: edgeAnchor).combined(with: .opacity),
            removal: .scale(scale: 0.85, anchor: edgeAnchor).combined(with: .opacity)
        )
    }

    // MARK: Collapsed

    /// The nearest-to-limit account tints the collapsed hairline and lights
    /// it along its length, so you get peripheral warning without opening
    /// anything: a short line is headroom, a full amber one is not.
    private var hairline: some View {
        let headroom = manager.railHeadroom
        // A fixed height, centred — not tied to the window — so it never
        // stretches when the window resizes for the card; the card simply
        // grows over it as one motion.
        return RailHairline(reduceMotion: reduceMotion, accent: headroom.accent, fill: headroom.fill)
            .frame(width: 7, height: 150)
            .accessibilityElement()
            .accessibilityLabel("AIrail")
            .accessibilityValue(headroom.spoken())
            .accessibilityHint("Move the pointer here to expand the usage rail.")
    }
}

// MARK: - Expanded rail

/// The expanded card. Reveals as one motion (the rail's insertion transition);
/// individual marks only do the Dock-style magnify on hover.
private struct ExpandedRailContent: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var manager: ProviderManager
    @ObservedObject var ui: RailUIState
    var reduceMotion: Bool
    var onSelect: (String) -> Void

    @State private var hoveredProviderId: String?

    var body: some View {
        VStack(spacing: 16) {
            let infos = manager.railProviderInfos
            ForEach(Array(infos.enumerated()), id: \.element.id) { index, info in
                logoButton(info: info, index: index)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 10)
        .background(card)
        .shadow(
            color: .black.opacity(0.35),
            radius: 14,
            x: settings.railSide == .left ? 4 : -4,
            y: 2
        )
    }

    private func logoButton(info: ProviderInfo, index: Int) -> some View {
        let snapshot = manager.snapshot(for: info.id)
        let isHovered = hoveredProviderId == info.id && !reduceMotion
        return VStack(spacing: 5) {
            Button {
                onSelect(info.id)
            } label: {
                LogoMark(
                    color: info.color,
                    symbolName: info.symbolName,
                    brandIconPath: info.brandIconPath,
                    percent: snapshot?.ringPercent,
                    size: 44,
                    isSelected: ui.selectedProviderId == info.id,
                    elapsed: snapshot?.status == .ok ? snapshot?.pace()?.elapsed : nil
                )
            }
            .buttonStyle(.plain)
            // Dock-style magnification on hover, on the mark only.
            .scaleEffect(isHovered ? 1.16 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isHovered)
            .onHover { hovering in
                if hovering {
                    hoveredProviderId = info.id
                } else if hoveredProviderId == info.id {
                    hoveredProviderId = nil
                }
            }
            VStack(spacing: 1) {
                Text(info.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                percentCaption(snapshot)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                    .monospacedDigit()
            }
            .lineLimit(1)
        }
        // No per-cell entrance: the whole card unfurls as one motion (the
        // rail's insertion transition), so the reveal reads as a single move.
        .help(helpText(info: info, snapshot: snapshot))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(info.displayName)
        .accessibilityValue(UsageFormatting.spokenUsage(snapshot))
    }

    /// The percent — or, at the wall, the time until it lifts, ticking once
    /// a minute. That is the one moment people stare at the rail.
    @ViewBuilder
    private func percentCaption(_ snapshot: UsageSnapshot?) -> some View {
        if let wall = snapshot?.atLimitResetsAt {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(UsageFormatting.countdown(to: wall, now: context.date))
            }
        } else {
            Text(snapshot?.ringPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                .contentTransition(.numericText(value: snapshot?.ringPercent ?? 0))
                .animation(.default, value: snapshot?.ringPercent)
        }
    }

    private var card: some View {
        GlassPanel(shape: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func helpText(info: ProviderInfo, snapshot: UsageSnapshot?) -> String {
        if let wall = snapshot?.atLimitResetsAt {
            return "\(info.displayName) — limit reached, resets in \(UsageFormatting.countdown(to: wall))"
        }
        if let percent = snapshot?.ringPercent {
            return "\(info.displayName) — \(Int(percent.rounded()))%"
        }
        return info.displayName
    }
}
