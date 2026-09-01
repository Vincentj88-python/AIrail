import SwiftUI

@MainActor
final class CodexProvider: UsageProviding {
    let id = "codex"
    let displayName = "Codex"
    let color = Color(hex: 0xA855F7)
    let symbolName = "terminal"

    private let mock = MockUsageEngine(profile: .init(
        plan: "Plus",
        sessionStart: 33,
        weeklyLimit: 3000,
        weeklyStart: 38,
        credits: nil,
        spend: nil,
        spendCap: nil
    ))

    func isInstalled() -> Bool {
        InstallDetection.anyExists([".codex"])
    }

    func fetchUsage() async -> UsageSnapshot {
        mock.snapshot(providerId: id, displayName: displayName)
    }
}
