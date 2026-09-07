import Foundation

/// Developer conveniences read from the command line, so UI states that
/// normally take clicks can be opened straight from a launch:
///
///     AIrail --settings=accounts --add-account[=other]
///     AIrail --overlay=claude
///     AIrail --expanded --demo=91      (scripts/screenshots.sh)
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

    /// `--expanded` opens the rail (or the island) as if hovered, for captures.
    static var expandsOnLaunch: Bool {
        value(for: "--expanded") != nil
    }

    /// `--demo=91` raises the busiest demo account's session figure to that
    /// percent, so a capture can show the amber or red states honestly badged demo.
    static var demoPeak: Double? {
        demoPeak(in: CommandLine.arguments)
    }

    static func demoPeak(in arguments: [String]) -> Double? {
        guard let raw = value(for: "--demo", in: arguments), let peak = Double(raw) else { return nil }
        return UsageSnapshot.clampPercent(peak)
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
    private static func value(for flag: String, in arguments: [String] = CommandLine.arguments) -> String? {
        guard let argument = arguments.first(where: { $0 == flag || $0.hasPrefix(flag + "=") }) else {
            return nil
        }
        return argument.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
    }
}
