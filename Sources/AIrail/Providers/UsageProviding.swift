import SwiftUI

@MainActor
protocol UsageProviding: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var color: Color { get }
    var symbolName: String { get }
    /// Real brand mark as SVG path data; nil falls back to `symbolName`.
    var brandIconPath: String? { get }
    /// How this provider borrows the sign-in already on the Mac.
    var connection: ConnectionMethod { get }
    var kind: ProviderKind { get }
    /// Demo profile used while no account is connected.
    var demoProfile: MockUsageEngine.Profile { get }
    func isInstalled() -> Bool
    /// A real read of the account's usage. Throws a `ConnectionError` when the
    /// sign-in can't be found, read, or used; never returns invented numbers.
    func fetchUsage() async throws -> UsageSnapshot
    /// The same read, saying whether the user asked for it. Only an
    /// interactive read may put up a macOS dialog; the timer's never do.
    func fetchUsage(interactive: Bool) async throws -> UsageSnapshot
    /// The account was removed: drop anything kept of the borrowed sign-in.
    func forgetBorrowedSignIn()
}

extension UsageProviding {
    var brandIconPath: String? { nil }
    var kind: ProviderKind { .tool }
    func fetchUsage(interactive: Bool) async throws -> UsageSnapshot { try await fetchUsage() }
    func forgetBorrowedSignIn() {}
}

/// A provider whose data comes from an API key the user pastes. The key lives
/// in AIrail's own Keychain item and is forgotten when the account is removed.
@MainActor
protocol KeyedUsageProviding: UsageProviding {
    var platform: KeyedPlatform { get }
    var hasKey: Bool { get }
    func storeKey(_ key: String) throws
    func forgetKey()
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
