import SwiftUI

@MainActor
protocol UsageProviding: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var color: Color { get }
    var symbolName: String { get }
    func isInstalled() -> Bool
    func fetchUsage() async -> UsageSnapshot
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
