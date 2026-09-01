import SwiftUI

@MainActor
final class CursorProvider: UsageProviding {
    let id = "cursor"
    let displayName = "Cursor"
    let color = Color(hex: 0x3B82F6)
    let symbolName = "chevron.left.forwardslash.chevron.right"
    let brandIconPath: String? = BrandIcons.cursor

    private let mock = MockUsageEngine(profile: .init(
        plan: "Pro",
        sessionStart: 62,
        weeklyLimit: 2000,
        weeklyStart: 62,
        credits: 8760,
        spend: 18.40,
        spendCap: 60
    ))

    func isInstalled() -> Bool {
        InstallDetection.anyExists([".cursor", "Library/Application Support/Cursor"])
    }

    func fetchUsage() async -> UsageSnapshot {
        mock.snapshot(providerId: id, displayName: displayName)
    }
}
