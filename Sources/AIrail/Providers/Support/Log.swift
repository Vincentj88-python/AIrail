import Foundation
import OSLog

/// The app's log, one `Logger` per area, under the bundle id so Console and
/// Save Diagnostics… can find it. Interpolated values are private by default
/// (they read back as `<private>`); only hosts, status codes, provider ids
/// and counts are marked public — never a header, a body, a key or who is
/// signed in.
enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.codeandvin.airail"

    static let refresh = Logger(subsystem: subsystem, category: "refresh")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let window = Logger(subsystem: subsystem, category: "window")
    static let keychain = Logger(subsystem: subsystem, category: "keychain")
    static let update = Logger(subsystem: subsystem, category: "update")
}
