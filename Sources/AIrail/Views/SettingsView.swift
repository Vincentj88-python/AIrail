import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var manager: ProviderManager
    @ObservedObject var ui: RailUIState

    var body: some View {
        TabView(selection: $ui.settingsTab) {
            GeneralPane(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(RailUIState.SettingsTab.general)
            RailPane(settings: settings)
                .tabItem { Label("Rail", systemImage: "sidebar.left") }
                .tag(RailUIState.SettingsTab.rail)
            AccountsPane(settings: settings, manager: manager)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                .tag(RailUIState.SettingsTab.accounts)
        }
        .frame(width: 640)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var settings: AppSettings

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Picker("Refresh interval", selection: $settings.refreshInterval) {
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                }
            } footer: {
                Text("Each connected account is read again at this interval. Nothing is sent anywhere except each tool's own usage check.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 230)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Couldn't update login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Rail

private struct RailPane: View {
    @ObservedObject var settings: AppSettings

    private var displayNames: [String] { ScreenSelection.displayNames }

    private var notchAvailable: Bool {
        ScreenSelection.notchAvailable(preference: settings.railDisplay)
    }

    /// Notch is offered only for the display that has one (a stored choice
    /// still shows so it can be changed).
    private var availablePositions: [AppSettings.RailPosition] {
        notchAvailable || settings.position == .notch ? AppSettings.RailPosition.allCases : [.left, .right]
    }

    private var displayFooter: String {
        if settings.railDisplay == ScreenSelection.automatic {
            let side = settings.railSide == .left ? "left" : "right"
            let chosen = ScreenSelection.railScreen(preference: settings.railDisplay, side: settings.railSide)?.localizedName ?? "—"
            return "Automatic uses the outer \(side) edge of your whole desktop — currently \(chosen) — so the pointer stops on the rail instead of crossing onto the next display."
        }
        if let screen = ScreenSelection.screen(named: settings.railDisplay), ScreenSelection.hasNotch(screen) {
            return "\(screen.localizedName) has a notch, so Notch is available as a position."
        }
        return "Only the MacBook's built-in display has a notch; other displays offer Left and Right."
    }

    private var positionFooter: String? {
        guard settings.position != .notch,
              let screen = ScreenSelection.railScreen(preference: settings.railDisplay, side: settings.railSide),
              let neighbour = ScreenSelection.neighbour(beyond: screen, side: settings.railSide)
        else { return nil }
        return "This edge of \(screen.localizedName) continues onto \(neighbour.localizedName), so the pointer will cross over rather than rest on the rail. Pick the other side, or the display at the outer edge."
    }

    var body: some View {
        Form {
            Section {
                Picker("Display", selection: $settings.railDisplay) {
                    Text("Automatic — outer edge").tag(ScreenSelection.automatic)
                    Divider()
                    ForEach(displayNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .onChange(of: settings.railDisplay) { _, _ in
                    // Notch only exists on one display; leaving it means an edge.
                    if settings.position == .notch, !notchAvailable {
                        settings.position = .left
                    }
                }
            } footer: {
                Text(displayFooter)
            }
            Section {
                Picker("Position", selection: $settings.position) {
                    ForEach(availablePositions) { position in
                        Text(position.label).tag(position)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                if settings.position == .notch {
                    Text("Notch folds the rail into the notch: a hairline under it, a Dynamic Island-style row of marks on hover, the HUD beneath. Falls back to the left edge whenever that display isn't attached.")
                } else if let positionFooter {
                    Text(positionFooter)
                } else {
                    Text("Left and Right hug that edge of the chosen display; hover the hairline to expand the rail.")
                }
            }
            Section {
                HStack {
                    Slider(value: $settings.autoHideDelay, in: 0...2, step: 0.1) {
                        Text("Auto-hide delay")
                    }
                    Text(String(format: "%.1fs", settings.autoHideDelay))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            } footer: {
                Text("How long the expanded rail stays open after the pointer leaves it.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 360)
    }
}
