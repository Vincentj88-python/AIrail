import Foundation
import SwiftUI

/// A platform with a documented usage or credits API, connected by pasting a
/// key — Internet Accounts' "Add Other Account…". One catalog entry per
/// platform; the fetch closure turns a key into a snapshot.
struct KeyedPlatform: Identifiable, Sendable {
    typealias Fetch = @Sendable (_ key: String, _ providerId: String, _ displayName: String) async throws -> UsageSnapshot

    let id: String
    let displayName: String
    let color: Color
    let symbolName: String
    var brandIconPath: String? = nil
    /// "API key" or "Admin key" — what the field asks for.
    let keyKind: String
    let keyPlaceholder: String
    /// Where to create the key, for the sheet's help link.
    let keyURL: URL?
    let connection: ConnectionMethod
    let fetch: Fetch
}

@MainActor
final class KeyedProvider: KeyedUsageProviding {
    let platform: KeyedPlatform

    var id: String { platform.id }
    var displayName: String { platform.displayName }
    var color: Color { platform.color }
    var symbolName: String { platform.symbolName }
    var brandIconPath: String? { platform.brandIconPath }
    var connection: ConnectionMethod { platform.connection }
    var kind: ProviderKind { .apiKey }

    let demoProfile = MockUsageEngine.Profile(
        plan: "API", sessionStart: 20, weeklyLimit: 100, weeklyStart: 20,
        credits: 42, spend: 12.5, spendCap: 50
    )

    private var cachedKey: String?

    init(platform: KeyedPlatform) {
        self.platform = platform
    }

    /// Keyed platforms have nothing on disk to detect.
    func isInstalled() -> Bool { false }

    var hasKey: Bool {
        if cachedKey != nil { return true }
        return (try? KeychainStore.get(account: id)) != nil
    }

    func storeKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConnectionError.missingKey(platform: displayName) }
        try KeychainStore.set(trimmed, account: id)
        cachedKey = trimmed
    }

    func forgetKey() {
        KeychainStore.delete(account: id)
        cachedKey = nil
    }

    func fetchUsage() async throws -> UsageSnapshot {
        let key: String
        if let cachedKey {
            key = cachedKey
        } else {
            let account = id
            let stored = try await Task.detached { () throws -> String? in
                try KeychainStore.get(account: account)
            }.value
            guard let stored else {
                throw ConnectionError.missingKey(platform: displayName)
            }
            cachedKey = stored
            key = stored
        }
        do {
            return try await platform.fetch(key, id, displayName)
        } catch ConnectionError.expired {
            throw ConnectionError.invalidKey(platform: displayName, hint: platform.keyKind == "Admin key"
                ? "It must be an organization Admin key, not a regular API key."
                : nil)
        }
    }
}
