import SwiftUI

@MainActor
final class CopilotProvider: UsageProviding {
    let id = "copilot"
    let displayName = "Copilot"
    let color = Color(hex: 0x9CA3AF)
    let symbolName = "cpu"
    let brandIconPath: String? = BrandIcons.copilot

    private let mock = MockUsageEngine(profile: .init(
        plan: "Pro",
        sessionStart: 18,
        weeklyLimit: 300,
        weeklyStart: 22,
        credits: nil,
        spend: nil,
        spendCap: nil
    ))

    func isInstalled() -> Bool {
        InstallDetection.onPath("gh")
            || InstallDetection.anyExists(["Library/Application Support/GitHub Copilot"])
    }

    func fetchUsage() async -> UsageSnapshot {
        mock.snapshot(providerId: id, displayName: displayName)
    }
}
