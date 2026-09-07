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

    /// True under `xcodebuild test`, where the app is only the test host and
    /// must not go reading sign-ins or endpoints on its own.
    static var isRunningTests: Bool {
        isRunningTests(in: ProcessInfo.processInfo.environment)
    }

    /// Xcode 16 hands the host its session id and bundle path; the
    /// configuration file path is what older Xcodes set, kept as a fallback.
    static func isRunningTests(in environment: [String: String]) -> Bool {
        ["XCTestSessionIdentifier", "XCTestBundlePath", "XCTestConfigurationFilePath"]
            .contains { environment[$0] != nil }
    }

    /// `--flag` yields "", `--flag=x` yields "x", absent yields nil.
    private static func value(for flag: String) -> String? {
        guard let argument = CommandLine.arguments.first(where: { $0 == flag || $0.hasPrefix(flag + "=") }) else {
            return nil
        }
        return argument.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
    }
}
