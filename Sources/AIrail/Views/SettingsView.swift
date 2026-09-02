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

    var body: some View {
        Form {
            Section {
                Picker("Rail side", selection: $settings.railSide) {
                    ForEach(AppSettings.RailSide.allCases) { side in
                        Text(side.label).tag(side)
                    }
                }
                .pickerStyle(.segmented)
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
        .frame(height: 230)
    }
}
