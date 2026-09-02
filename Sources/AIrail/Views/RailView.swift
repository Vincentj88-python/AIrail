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

    private var hairline: some View {
        CascadingHairline(
            colors: manager.railProviderInfos.map(\.color),
            reduceMotion: reduceMotion
        )
            .frame(width: 7)
            .frame(maxHeight: .infinity)
            .padding(.vertical, 2)
            .accessibilityElement()
            .accessibilityLabel("AIrail")
            .accessibilityHint("Move the pointer here to expand the usage rail.")
    }
}

// MARK: - Expanded rail

/// The expanded card. Owns the entrance stagger (logos cascade in one after
/// another) and the Dock-style magnify-on-hover for individual logos.
private struct ExpandedRailContent: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var manager: ProviderManager
    @ObservedObject var ui: RailUIState
    var reduceMotion: Bool
    var onSelect: (String) -> Void

    @State private var appeared = false
    @State private var hoveredProviderId: String?

    var body: some View {
        VStack(spacing: 14) {
            let infos = manager.railProviderInfos
            ForEach(Array(infos.enumerated()), id: \.element.id) { index, info in
                logoButton(info: info, index: index)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 9)
        .background(card)
        .shadow(
            color: .black.opacity(0.35),
            radius: 14,
            x: settings.railSide == .left ? 4 : -4,
            y: 2
        )
        .onAppear { appeared = true }
    }

    private func logoButton(info: ProviderInfo, index: Int) -> some View {
        let snapshot = manager.snapshot(for: info.id)
        let isHovered = hoveredProviderId == info.id && !reduceMotion
        return Button {
            onSelect(info.id)
        } label: {
            LogoMark(
                color: info.color,
                symbolName: info.symbolName,
                brandIconPath: info.brandIconPath,
                percent: snapshot?.ringPercent,
                size: 44,
                isSelected: ui.selectedProviderId == info.id
            )
        }
        .buttonStyle(.plain)
        // Dock-style magnification on hover.
        .scaleEffect(isHovered ? 1.16 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isHovered)
        .onHover { hovering in
            if hovering {
                hoveredProviderId = info.id
            } else if hoveredProviderId == info.id {
                hoveredProviderId = nil
            }
        }
        // Staggered entrance: each logo pops in slightly after the previous.
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.4)
        .offset(x: appeared || reduceMotion ? 0 : (settings.railSide == .left ? -14 : 14))
        .animation(entranceAnimation(index: index), value: appeared)
        .help(helpText(info: info, snapshot: snapshot))
        .accessibilityLabel(info.displayName)
        .accessibilityValue(
            snapshot?.ringPercent.map { "\(Int($0.rounded())) percent used" } ?? "no data"
        )
    }

    private func entranceAnimation(index: Int) -> Animation {
        reduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: 0.4, dampingFraction: 0.62).delay(0.04 + Double(index) * 0.045)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.black.opacity(0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09))
            )
    }

    private func helpText(info: ProviderInfo, snapshot: UsageSnapshot?) -> String {
        if let percent = snapshot?.ringPercent {
            return "\(info.displayName) — \(Int(percent.rounded()))%"
        }
        return info.displayName
    }
}

// MARK: - Cascading hairline

/// Collapsed-state hairline: a 3 pt line that wears ONE provider color at a
/// time. Each color holds for a few seconds, then the next enabled provider's
/// color washes down through the bar. Never a rainbow — at most two colors
/// are visible, and only during the handoff.
private struct CascadingHairline: View {
    var colors: [Color]
    var reduceMotion: Bool

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

    /// One bar-height zone per color: 75% solid hold, 25% blend into the next.
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
            let height = geo.size.height
            let loopDuration = Self.perColorDuration * Double(max(1, displayColors.count))
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                let phase = reduceMotion
                    ? 0
                    : CGFloat((time / loopDuration).truncatingRemainder(dividingBy: 1))
                ZStack {
                    // soft glow, cascading in sync with the core
                    band(height: height, phase: phase)
                        .frame(width: 5)
                        .blur(radius: 4)
                        .opacity(0.32)
                    // core line, kept muted
                    band(height: height, phase: phase)
                        .frame(width: 3)
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

    /// The full color strip is `count` bar-heights tall, so the visible
    /// window shows a single color zone at a time. Doubled and scrolled by
    /// `phase`, masked to a capsule, so it wraps without a visible seam.
    private func band(height: CGFloat, phase: CGFloat) -> some View {
        let stripHeight = height * CGFloat(max(1, displayColors.count))
        return VStack(spacing: 0) {
            gradientBlock(stripHeight: stripHeight)
            gradientBlock(stripHeight: stripHeight)
        }
        .offset(y: (phase - 1) * stripHeight)
        .frame(height: height, alignment: .top)
        .mask(Capsule(style: .continuous))
    }

    private func gradientBlock(stripHeight: CGFloat) -> some View {
        LinearGradient(gradient: stripGradient, startPoint: .top, endPoint: .bottom)
            .frame(height: stripHeight)
    }
}
