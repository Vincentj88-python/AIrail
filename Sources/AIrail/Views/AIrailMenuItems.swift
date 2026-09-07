import AppKit
import SwiftUI

/// The one menu behind the rail's right-click, the island's right-click and
/// the card's ⋯ button: Settings, the update item, About, Report a Problem,
/// Save Diagnostics, Quit. One place, so a new item is added once.
struct AIrailMenuItems: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var manager: ProviderManager
    @ObservedObject var ui: RailUIState

    @Environment(\.openSettings) private var openSettings

    var body: some View {
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
        Button("About AIrail") {
            Diagnostics.showAbout()
        }
        Button("Report a Problem…") {
            Diagnostics.reportProblem(manager: manager, settings: settings)
        }
        Button("Save Diagnostics…") {
            Task { await Diagnostics.saveReport(manager: manager, settings: settings) }
        }
        Divider()
        Button("Quit AIrail") {
            NSApp.terminate(nil)
        }
    }
}
