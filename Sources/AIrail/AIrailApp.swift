import SwiftUI

@main
struct AIrailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView(settings: delegate.settings, manager: delegate.providerManager)
        }
    }
}
