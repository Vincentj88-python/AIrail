import SwiftUI

@MainActor
final class GeminiProvider: UsageProviding {
    let id = "gemini"
    let displayName = "Gemini"
    let color = Color(hex: 0x14B8A6)
    let symbolName = "sparkle"

    private let mock = MockUsageEngine(profile: .init(
        plan: "Pro",
        sessionStart: 55,
        weeklyLimit: 1000,
        weeklyStart: 52,
        credits: nil,
        spend: nil,
        spendCap: nil
    ))

    func isInstalled() -> Bool {
        InstallDetection.anyExists([".gemini"]) || InstallDetection.onPath("gcloud")
    }

    func fetchUsage() async -> UsageSnapshot {
        mock.snapshot(providerId: id, displayName: displayName)
    }
}
