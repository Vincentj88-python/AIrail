import Foundation

/// Developer conveniences read from the command line, so UI states that
/// normally take clicks can be opened straight from a launch:
///
///     AIrail --settings=accounts --add-account[=other]
///     AIrail --overlay=claude
enum LaunchOptions {
    static var settingsTab: RailUIState.SettingsTab? {
        guard let flag = value(for: "--settings") else { return nil }
        return RailUIState.SettingsTab(rawValue: flag) ?? .general
    }

    static var opensAddAccount: Bool {
        value(for: "--add-account") != nil
    }

    /// `--add-account=other` opens the sheet on its API-key page.
    static var opensOtherAccounts: Bool {
        value(for: "--add-account") == "other"
    }

    static var overlayProviderId: String? {
        value(for: "--overlay").flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `--flag` yields "", `--flag=x` yields "x", absent yields nil.
    private static func value(for flag: String) -> String? {
        guard let argument = CommandLine.arguments.first(where: { $0 == flag || $0.hasPrefix(flag + "=") }) else {
            return nil
        }
        return argument.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
    }
}
