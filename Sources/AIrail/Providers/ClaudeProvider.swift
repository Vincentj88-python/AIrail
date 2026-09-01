import SwiftUI

@MainActor
final class ClaudeProvider: UsageProviding {
    let id = "claude"
    let displayName = "Claude"
    let color = Color(hex: 0xF97316)
    let symbolName = "sparkles"

    private let mock = MockUsageEngine(profile: .init(
        plan: "Max",
        sessionStart: 41,
        weeklyLimit: 480,
        weeklyStart: 47,
        credits: nil,
        spend: nil,
        spendCap: nil
    ))

    func isInstalled() -> Bool {
        InstallDetection.anyExists([".claude", "Library/Application Support/Claude"])
    }

    func fetchUsage() async -> UsageSnapshot {
        mock.snapshot(providerId: id, displayName: displayName)
    }
}
