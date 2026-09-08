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
            PrivacyPane(settings: settings, manager: manager)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
                .tag(RailUIState.SettingsTab.privacy)
        }
        .frame(width: 640)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var settings: AppSettings

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    /// The toggle is on but macOS says no: point at the switch that matters.
    @State private var notificationsDenied = false
    /// The pane asks at most once per showing (see `readNotificationStatus`).
    @State private var askedForPermission = false

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
            Section {
                Toggle("Notify me about usage", isOn: $settings.notificationsEnabled)
                    .onChange(of: settings.notificationsEnabled) { _, enabled in
                        // The one-time system prompt comes with the toggle, not the first alert.
                        if enabled {
                            Task { notificationsDenied = await UsageNotifier.requestPermission() == .denied }
                        }
                    }
                if settings.notificationsEnabled, notificationsDenied {
                    HStack(spacing: 8) {
                        Text("Notifications for AIrail are turned off in System Settings.")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open System Settings…") {
                            if let url = UsageNotifier.systemSettingsURL {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                    .font(.caption)
                }
            } footer: {
                Text("A macOS notification when an account passes 75% or 90%, and one when that window resets so you can batch heavy work. Click one to open that account's HUD.")
            }
            Section {
                // The commit only appears on a release.sh build (see BuildInfo).
                LabeledContent("Version", value: BuildInfo.label)
            }
        }
        .formStyle(.grouped)
        .frame(height: 380)
        .task { await readNotificationStatus() }
        // Back from System Settings: the row above should follow what was changed there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await readNotificationStatus() }
        }
    }

    private func readNotificationStatus() async {
        var status = await UsageNotifier.systemStatus()
        // The toggle is on but macOS was never answered — the prompt was up
        // when AIrail quit, or the permission was reset in System Settings.
        // No background path may ask, so this pane does, once; otherwise the
        // toggle would read on and stay silent for good.
        if status == .notDetermined, settings.notificationsEnabled, !askedForPermission {
            askedForPermission = true
            status = await UsageNotifier.requestPermission()
        }
        notificationsDenied = status == .denied
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

    private var selectedDisplayHasNotch: Bool {
        ScreenSelection.screen(named: settings.railDisplay).map(ScreenSelection.hasNotch) ?? false
    }

    private var displayFooter: String {
        if settings.railDisplay == ScreenSelection.automatic {
            let side = settings.railSide == .left ? "left" : "right"
            let chosen = ScreenSelection.railScreen(preference: settings.railDisplay, side: settings.railSide)?.localizedName ?? "—"
            return "Automatic uses the outer \(side) edge of your whole desktop — currently \(chosen) — so the pointer stops on the rail instead of crossing onto the next display."
        }
        if let screen = ScreenSelection.screen(named: settings.railDisplay), ScreenSelection.hasNotch(screen) {
            return "\(screen.localizedName) has a notch, so Top folds the rail into it."
        }
        return "Only the MacBook's built-in display has a notch; on any other, Top is a hairline at the top centre."
    }

    private var positionFooter: String? {
        guard !settings.position.isTop,
              let screen = ScreenSelection.railScreen(preference: settings.railDisplay, side: settings.railSide),
              let neighbour = ScreenSelection.neighbour(beyond: screen, side: settings.railSide)
        else { return nil }
        return "This edge of \(screen.localizedName) continues onto \(neighbour.localizedName), so the pointer will cross over rather than rest on the rail. Pick the other side, or the display at the outer edge."
    }

    private var autoHideFooter: String {
        if settings.position.isTop {
            return "Top always hides: the island shows on hover and tucks back under the notch."
        }
        if settings.railAutoHides {
            return "How long the expanded rail stays open after the pointer leaves it."
        }
        return "The rail stays open on the edge of the display. It floats over your windows rather than reserving space, the way a pinned Dock would."
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
            } footer: {
                Text(displayFooter)
            }
            Section {
                Picker("Position", selection: $settings.position) {
                    ForEach(AppSettings.RailPosition.allCases) { position in
                        Text(position.label).tag(position)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                if settings.position == .top {
                    Text(selectedDisplayHasNotch || (settings.railDisplay == ScreenSelection.automatic && notchAvailable)
                         ? "Top folds the rail into the notch: a hairline under it, a Dynamic Island-style row of marks on hover, the HUD beneath."
                         : "Top is a hairline at the top centre of the display, under the menu bar; hover it and an island of marks grows down, the HUD beneath. Nothing sits over the menu bar until you hover.")
                } else if let positionFooter {
                    Text(positionFooter)
                } else {
                    Text("Left and Right hug that edge of the chosen display; hover the hairline to expand the rail.")
                }
            }
            Section {
                Toggle("Automatically hide the rail", isOn: $settings.railAutoHides)
                    .disabled(settings.position.isTop)
                HStack {
                    Slider(value: $settings.autoHideDelay, in: 0...2, step: 0.1) {
                        Text("Auto-hide delay")
                    }
                    Text(String(format: "%.1fs", settings.autoHideDelay))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                .disabled(!settings.railAutoHides || settings.position.isTop)
            } footer: {
                Text(autoHideFooter)
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
    }
}
