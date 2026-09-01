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
        Capsule(style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.teal.opacity(0.75),
                                Color.blue.opacity(0.55),
                                Color.teal.opacity(0.75),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .frame(width: 5)
            .frame(maxHeight: .infinity)
            .padding(.vertical, 2)
            .shadow(color: .teal.opacity(0.5), radius: 6)
            .opacity(0.9)
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
