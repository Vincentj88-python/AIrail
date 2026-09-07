import Foundation

/// What this build is: the marketing version, plus the short commit that
/// `scripts/release.sh` stamps into Info.plist before signing. A build straight
/// from Xcode carries no commit and says only its version.
enum BuildInfo {
    /// The Info.plist key release.sh writes with PlistBuddy.
    static let commitKey = "AIrailCommit"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// `0a744d2` (or `0a744d2-dirty`) for a release build; nil when unstamped.
    static var commit: String? {
        (Bundle.main.infoDictionary?[commitKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "0.2.0 (0a744d2)" for a release, "0.2.0" for an Xcode build.
    static var label: String { label(version: version, commit: commit) }

    static func label(version: String, commit: String?) -> String {
        guard let commit else { return version }
        return "\(version) (\(commit))"
    }
}
