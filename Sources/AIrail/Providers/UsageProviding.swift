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
    /// Demo profile used while no account is connected.
    var demoProfile: MockUsageEngine.Profile { get }
    func isInstalled() -> Bool
    /// A real read of the account's usage. Throws a `ConnectionError` when the
    /// sign-in can't be found, read, or used; never returns invented numbers.
    func fetchUsage() async throws -> UsageSnapshot
}

extension UsageProviding {
    var brandIconPath: String? { nil }
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
