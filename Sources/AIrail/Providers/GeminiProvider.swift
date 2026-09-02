import Foundation
import SwiftUI

/// Listed so the demo rail and the picker know it exists; not connectable
/// until a verified way to read Gemini's quota exists.
@MainActor
final class GeminiProvider: UsageProviding {
    let id = "gemini"
    let displayName = "Gemini"
    let color = Color(hex: 0x14B8A6)
    let symbolName = "sparkle"
    let brandIconPath: String? = BrandIcons.gemini

    let connection = ConnectionMethod(
        toolName: "Gemini CLI",
        summary: "Coming soon",
        explainer: "Gemini CLI keeps its Google sign-in in ~/.gemini, but Google doesn't yet offer a dependable way to read the quota that sign-in has left. Until one exists AIrail won't show made-up numbers for Gemini.",
        isSupported: false
    )

    let demoProfile = MockUsageEngine.Profile(
        plan: "Pro", sessionStart: 55, weeklyLimit: 1000, weeklyStart: 52,
        credits: nil, spend: nil, spendCap: nil,
        demoModels: ["gemini-3-pro", "gemini-3-flash"]
    )

    func isInstalled() -> Bool {
        InstallDetection.anyExists([".gemini"]) || InstallDetection.onPath("gcloud")
    }

    func fetchUsage() async throws -> UsageSnapshot {
        throw ConnectionError.unsupported
    }
}
