import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var manager: ProviderManager

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("Rail") {
                Picker("Rail side", selection: $settings.railSide) {
                    ForEach(AppSettings.RailSide.allCases) { side in
                        Text(side.label).tag(side)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Slider(value: $settings.autoHideDelay, in: 0...2, step: 0.1) {
                        Text("Auto-hide delay")
                    }
                    Text(String(format: "%.1fs", settings.autoHideDelay))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }

            Section("Data") {
                Picker("Refresh interval", selection: $settings.refreshInterval) {
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                }
                Text("All numbers are demo data in this build. Live provider APIs come later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Providers") {
                Text("Tools detected on this Mac were enabled automatically on first launch. Toggle any on or off — the rail only shows what you enable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(manager.allProviderInfos) { info in
                    Toggle(isOn: enabledBinding(for: info.id)) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(info.color)
                                .frame(width: 8, height: 8)
                            Text(info.displayName)
                            Spacer()
                            Text(info.installed ? "detected" : "not detected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("General") {
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
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }

    private func enabledBinding(for providerId: String) -> Binding<Bool> {
        Binding(
            get: { settings.isEnabled(providerId) },
            set: { settings.setEnabled($0, providerId: providerId) }
        )
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
