import SwiftUI

/// The notch-mode rail: a hairline under the notch when idle, a black island
/// growing out of it with the provider marks on hover — Apple's Dynamic
/// Island, on the Mac that has the cut-out for it.
struct NotchView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var manager: ProviderManager
    @ObservedObject var ui: RailUIState
    var onSelect: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    @State private var hoveredId: String?

    private var expandAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 0.7)
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

    /// On a real notch the top area is a cut-out, so nothing is drawn there;
    /// on a display without one the same area is painted as the pill.
    private var hairline: some View {
        VStack(spacing: 0) {
            Group {
                if ui.notchIsVirtual {
                    pillShape
                        .fill(Color.black)
                        .overlay(pillShape.strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                } else {
                    Color.clear
                }
            }
            .frame(height: ui.notchSize.height)
            CascadingHairline(
                colors: manager.railProviderInfos.map(\.color),
                reduceMotion: reduceMotion,
                axis: .horizontal
            )
            .frame(height: 7)
            .padding(.horizontal, 16)
            .padding(.top, 1)
        }
        .accessibilityElement()
        .accessibilityLabel("AIrail")
        .accessibilityHint("Move the pointer to the notch to expand the usage island.")
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
        .frame(maxWidth: .infinity)
        .background(islandShape.fill(Color.black))
        .overlay(islandShape.strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
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
                if let percent = snapshot?.ringPercent {
                    Text("\(Int(percent.rounded()))%")
                        .fontWeight(.semibold)
                        .foregroundStyle(info.color)
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

    /// Flush with the top of the screen, rounded where it meets the desktop.
    private var islandShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: 0, bottomLeading: 20, bottomTrailing: 20, topTrailing: 0),
            style: .continuous
        )
    }

    /// The drawn notch: the same silhouette as the real one, at menu-bar height.
    private var pillShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: 0, bottomLeading: 12, bottomTrailing: 12, topTrailing: 0),
            style: .continuous
        )
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

    @State private var appeared = false

    var body: some View {
        HStack(spacing: NotchWindowController.markSpacing) {
            let infos = manager.railProviderInfos
            ForEach(Array(infos.enumerated()), id: \.element.id) { index, info in
                mark(info: info, index: index)
            }
        }
        .onAppear { appeared = true }
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
                onDark: true
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
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.4)
        .offset(y: appeared || reduceMotion ? 0 : -12)
        .animation(
            reduceMotion
                ? .easeInOut(duration: 0.18)
                : .spring(response: 0.4, dampingFraction: 0.62).delay(0.04 + Double(index) * 0.045),
            value: appeared
        )
        .help(snapshot?.ringPercent.map { "\(info.displayName) — \(Int($0.rounded()))%" } ?? info.displayName)
        .accessibilityLabel(info.displayName)
        .accessibilityValue(snapshot?.ringPercent.map { "\(Int($0.rounded())) percent used" } ?? "no data")
    }
}
