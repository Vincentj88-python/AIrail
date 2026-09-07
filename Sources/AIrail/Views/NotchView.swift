import SwiftUI

/// The Top position: a hairline under the notch (or under the menu bar's
/// centre on a display without one) when idle, an island growing out of it
/// with the provider marks on hover — Apple's Dynamic Island, on the Mac that
/// has the cut-out for it, and the same gesture where it doesn't.
struct NotchView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var manager: ProviderManager
    @ObservedObject var ui: RailUIState
    var onSelect: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    @State private var hoveredId: String?

    private var expandAnimation: Animation {
        // A liquid unfurl: quick, with a little overshoot as it settles.
        reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.5, dampingFraction: 0.66)
    }

    private var collapseAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.28, dampingFraction: 0.9)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            if ui.isExpanded {
                island
                    .transition(islandTransition)
            } else {
                hairline
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(ui.isExpanded ? expandAnimation : collapseAnimation, value: ui.isExpanded)
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

    /// The island grows down out of the notch and shrinks back into it.
    private var islandTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: 0.6, anchor: .top).combined(with: .opacity),
            removal: .scale(scale: 0.85, anchor: .top).combined(with: .opacity)
        )
    }

    // MARK: Collapsed

    /// Idle, nothing is drawn where the notch (or the menu bar's centre) is —
    /// transparent pixels pass clicks through — and the hairline sits just
    /// under it. Its own pixels are the hover target, as on the edge rail.
    private var hairline: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: ui.notchSize.height)
            RailHairline(reduceMotion: reduceMotion, axis: .horizontal, accent: railAccent)
            .frame(height: 7)
            .padding(.horizontal, 16)
            .padding(.top, 1)
        }
        .accessibilityElement()
        .accessibilityLabel("AIrail")
        .accessibilityHint("Move the pointer to the top centre of the display to expand the usage island.")
    }

    private var railAccent: Color {
        let peak = manager.railProviderInfos
            .compactMap { manager.snapshot(for: $0.id)?.peakPercent }
            .max()
        return UsageSeverity.of(peak).accent
    }

    // MARK: Expanded

    private var island: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: ui.notchSize.height)
            VStack(spacing: 3) {
                NotchMarksRow(
                    manager: manager,
                    ui: ui,
                    reduceMotion: reduceMotion,
                    hoveredId: $hoveredId,
                    onSelect: onSelect
                )
                caption
            }
            .padding(.horizontal, NotchWindowController.islandPadding)
            .padding(.top, 6)
            .padding(.bottom, 9)
            .frame(maxHeight: .infinity)
        }
        // Inset so the body sits inside the flare room the window reserves.
        .padding(.horizontal, NotchWindowController.islandFlare)
        .frame(maxWidth: .infinity)
        .background(islandBackground(islandShape))
        .overlay(islandShape.stroke(Color.white.opacity(0.1), lineWidth: 1))
        // A tight shadow that grounds the lower edge without hazing the desktop.
        .shadow(color: .black.opacity(ui.notchIsVirtual ? 0.3 : 0.28), radius: ui.notchIsVirtual ? 10 : 6, y: 4)
    }

    /// On a real notch the island is OLED black to merge with the physical
    /// cut-out; on a drawn Island it's the frosted dark glass of the rail and
    /// overlay, so the wallpaper shows faintly through.
    @ViewBuilder
    private func islandBackground(_ shape: some Shape) -> some View {
        if ui.notchIsVirtual {
            GlassPanel(shape: shape)
        } else {
            shape.fill(Color.black)
        }
    }

    /// Reveals the pointed-at (or open) provider's name and percent, the way
    /// the Dynamic Island shows detail. A fixed-height row so the marks above
    /// it never jump; it simply fades in.
    private var caption: some View {
        let id = hoveredId ?? ui.selectedProviderId
        let info = id.flatMap { manager.providerInfo(for: $0) }
        let snapshot = id.flatMap { manager.snapshot(for: $0) }
        return HStack(spacing: 6) {
            if let info {
                Text(info.displayName)
                    .foregroundStyle(.white.opacity(0.9))
                if let wall = snapshot?.atLimitResetsAt {
                    // At the wall the caption is the time until it lifts.
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(UsageFormatting.countdown(to: wall, now: context.date))
                            .fontWeight(.semibold)
                            .foregroundStyle(info.color)
                    }
                } else if let percent = snapshot?.ringPercent {
                    // Digits roll when this provider's number moves; a
                    // different provider is a different Text, not a roll.
                    Text("\(Int(percent.rounded()))%")
                        .fontWeight(.semibold)
                        .foregroundStyle(info.color)
                        .contentTransition(.numericText(value: percent))
                        .animation(.default, value: percent)
                        .id(info.id)
                } else if let plan = snapshot?.plan {
                    Text(plan)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
        .frame(height: 14)
        .opacity(info == nil ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: id)
        .accessibilityHidden(true)
    }

    /// The concave-filleted silhouette that melts out of the top edge.
    private var islandShape: IslandShape {
        IslandShape(flare: NotchWindowController.islandFlare, bottomRadius: 22)
    }
}

/// The horizontal row of marks inside the island, with the rail's entrance
/// stagger and Dock-style magnify.
private struct NotchMarksRow: View {
    @ObservedObject var manager: ProviderManager
    @ObservedObject var ui: RailUIState
    var reduceMotion: Bool
    @Binding var hoveredId: String?
    var onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: NotchWindowController.markSpacing) {
            let infos = manager.railProviderInfos
            ForEach(Array(infos.enumerated()), id: \.element.id) { index, info in
                mark(info: info, index: index)
            }
        }
    }

    private func mark(info: ProviderInfo, index: Int) -> some View {
        let snapshot = manager.snapshot(for: info.id)
        let isHovered = hoveredId == info.id && !reduceMotion
        return Button {
            onSelect(info.id)
        } label: {
            LogoMark(
                color: info.color,
                symbolName: info.symbolName,
                brandIconPath: info.brandIconPath,
                percent: snapshot?.ringPercent,
                size: NotchWindowController.markSize,
                isSelected: ui.selectedProviderId == info.id,
                onDark: true,
                elapsed: snapshot?.status == .ok ? snapshot?.pace()?.elapsed : nil
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.16 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isHovered)
        .onHover { hovering in
            if hovering {
                hoveredId = info.id
            } else if hoveredId == info.id {
                hoveredId = nil
            }
        }
        // No per-mark entrance: the island unfurls as one motion.
        .help(snapshot?.ringPercent.map { "\(info.displayName) — \(Int($0.rounded()))%" } ?? info.displayName)
        .accessibilityLabel(info.displayName)
        .accessibilityValue(UsageFormatting.spokenUsage(snapshot))
    }
}
