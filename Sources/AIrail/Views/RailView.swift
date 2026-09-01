import SwiftUI

struct RailView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var manager: ProviderManager
    @ObservedObject var ui: RailUIState
    var onSelect: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    private var railAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: 0.34, dampingFraction: 0.74)
    }

    private var edge: Alignment {
        settings.railSide == .left ? .leading : .trailing
    }

    private var edgePadding: Edge.Set {
        settings.railSide == .left ? .leading : .trailing
    }

    var body: some View {
        ZStack(alignment: edge) {
            Color.clear
            if ui.isExpanded {
                expandedRail
                    .padding(edgePadding, 6)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.9, anchor: settings.railSide == .left ? .leading : .trailing))
                    )
            } else {
                hairline
                    .padding(edgePadding, 4)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge)
        .animation(railAnimation, value: ui.isExpanded)
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

    // MARK: Collapsed

    private var hairline: some View {
        CascadingHairline(reduceMotion: reduceMotion)
            .frame(width: 7)
            .frame(maxHeight: .infinity)
            .padding(.vertical, 2)
            .accessibilityElement()
            .accessibilityLabel("AIrail")
            .accessibilityHint("Move the pointer here to expand the usage rail.")
    }

    // MARK: Expanded

    private var expandedRail: some View {
        VStack(spacing: 14) {
            ForEach(manager.enabledProviderInfos) { info in
                let snapshot = manager.snapshot(for: info.id)
                Button {
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
                .help(helpText(info: info, snapshot: snapshot))
                .accessibilityLabel(info.displayName)
                .accessibilityValue(
                    snapshot?.ringPercent.map { "\(Int($0.rounded())) percent used" } ?? "no data"
                )
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 9)
        .background(
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
        )
        .shadow(
            color: .black.opacity(0.35),
            radius: 14,
            x: settings.railSide == .left ? 4 : -4,
            y: 2
        )
    }

    private func helpText(info: ProviderInfo, snapshot: UsageSnapshot?) -> String {
        if let percent = snapshot?.ringPercent {
            return "\(info.displayName) — \(Int(percent.rounded()))%"
        }
        return info.displayName
    }
}

/// Collapsed-state hairline: a 3 pt line whose colors slowly cascade down
/// its length (the provider palette), with a soft matching glow behind it.
private struct CascadingHairline: View {
    var reduceMotion: Bool

    /// First color repeated last so the scrolling band tiles seamlessly.
    private static let cascade: [Color] = [
        Color(hex: 0x3B82F6), // Cursor blue
        Color(hex: 0xA855F7), // Codex purple
        Color(hex: 0xF97316), // Claude orange
        Color(hex: 0x22C55E), // ChatGPT green
        Color(hex: 0x14B8A6), // Gemini teal
        Color(hex: 0x3B82F6),
    ]

    private static let loopDuration: Double = 8

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                let phase = reduceMotion
                    ? 0
                    : CGFloat((time / Self.loopDuration).truncatingRemainder(dividingBy: 1))
                ZStack {
                    // soft glow, cascading in sync with the core
                    band(height: height, phase: phase)
                        .frame(width: 5)
                        .blur(radius: 4)
                        .opacity(0.55)
                    // bright core line
                    band(height: height, phase: phase)
                        .frame(width: 3)
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
                        )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// A doubled gradient scrolled by `phase` and masked to a capsule,
    /// so the colors flow downward and wrap without a visible seam.
    private func band(height: CGFloat, phase: CGFloat) -> some View {
        VStack(spacing: 0) {
            gradientBlock(height: height)
            gradientBlock(height: height)
        }
        .offset(y: (phase - 1) * height)
        .frame(height: height, alignment: .top)
        .mask(Capsule(style: .continuous))
    }

    private func gradientBlock(height: CGFloat) -> some View {
        LinearGradient(colors: Self.cascade, startPoint: .top, endPoint: .bottom)
            .frame(height: height)
    }
}
