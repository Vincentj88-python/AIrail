import SwiftUI

@MainActor
final class ChatGPTProvider: UsageProviding {
    let id = "chatgpt"
    let displayName = "ChatGPT"
    let color = Color(hex: 0x22C55E)
    let symbolName = "bubble.left.and.bubble.right"
    let brandIconPath: String? = BrandIcons.openAI

    private let mock = MockUsageEngine(profile: .init(
        plan: "Plus",
        sessionStart: 28,
        weeklyLimit: 160,
        weeklyStart: 31,
        credits: nil,
        spend: nil,
        spendCap: nil
    ))

    func isInstalled() -> Bool {
        InstallDetection.anyExists([".openai", ".codex"])
    }

    func fetchUsage() async -> UsageSnapshot {
        mock.snapshot(providerId: id, displayName: displayName)
    }
}
