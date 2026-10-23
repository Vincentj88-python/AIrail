import Foundation
import Security

/// Read-only access to a generic-password item another tool created. macOS
/// puts up its own "AIrail wants to use your confidential information…"
/// dialog when the item doesn't trust AIrail yet. That dialog is the consent
/// step, so it only ever appears after a click: background reads pass
/// `interactive: false` and fail instead of asking.
enum KeychainReader {
    /// Reads the item, retrying a few times before giving up: right after login
    /// the login Keychain can still be unlocking, and a tool rotating its own
    /// credential (Claude Code does, periodically) can make a read momentarily
    /// fail with a decode/"invalid record" error that clears on the next try.
    static func genericPassword(service: String, tool: String, interactive: Bool = true) throws -> Data {
        var lastStatus: OSStatus = errSecSuccess
        for attempt in 0..<3 {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            if !interactive {
                query.merge(noUI) { _, new in new }
            }
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                guard let data = item as? Data, !data.isEmpty else {
                    lastStatus = errSecDecode
                    break // retry — a rotating credential can be read mid-write
                }
                return data
            case errSecItemNotFound:
                throw ConnectionError.notSignedIn(tool: tool)
            case errSecInteractionNotAllowed where !interactive:
                // The item doesn't trust AIrail (any more): reading it would
                // put up the dialog, which waits for the user's click.
                Log.keychain.notice("\(tool, privacy: .public): needs consent")
                throw ConnectionError.needsConsent(tool: tool)
            case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
                // Prompt-related: don't hammer the dialog, let the caller retry later.
                Log.keychain.notice("\(tool, privacy: .public): access not allowed (\(status, privacy: .public))")
                throw ConnectionError.accessDenied(tool: tool)
            default:
                Log.keychain.notice("\(tool, privacy: .public): status \(status, privacy: .public), retrying")
                lastStatus = status // transient decode / busy — retry
            }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.15) }
        }
        // Persisted across retries: treat as temporary (Keychain locking after
        // sleep, or a credential rotation in progress) rather than a hard error,
        // so the last good numbers stay and the next refresh recovers on its own.
        _ = lastStatus
        throw ConnectionError.temporarilyUnavailable(tool: tool)
    }

    /// Which of the candidate items exists — the most recently modified when
    /// more than one does — and when it last changed. An attributes-only
    /// query is answered without the consent dialog, so this costs nothing
    /// and tells a renewed sign-in from one AIrail has already read.
    static func newestItem(_ services: [String]) -> (service: String, modified: Date)? {
        var found: [(service: String, modified: Date)] = []
        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { continue }
            let modified = (item as? [String: Any])?[kSecAttrModificationDate as String] as? Date ?? .distantPast
            found.append((service, modified))
        }
        return found.max { $0.modified < $1.modified }
    }

    /// Query keys that make a read fail with errSecInteractionNotAllowed
    /// rather than show the dialog. Apple's replacement (an LAContext with
    /// interactionNotAllowed) covers data-protection items, not the legacy
    /// login keychain where the tools keep their sign-ins, so this stays on
    /// the older constant knowingly.
    static var noUI: [String: Any] {
        [kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }
}
