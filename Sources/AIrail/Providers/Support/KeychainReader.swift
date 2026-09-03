import Foundation
import Security

/// Read-only access to a generic-password item another tool created. macOS
/// puts up its own "AIrail wants to use your confidential information…"
/// dialog on first read; that dialog is the consent step, deliberately.
enum KeychainReader {
    /// Reads the item, retrying a few times before giving up: right after login
    /// the login Keychain can still be unlocking, and a tool rotating its own
    /// credential (Claude Code does, periodically) can make a read momentarily
    /// fail with a decode/"invalid record" error that clears on the next try.
    static func genericPassword(service: String, tool: String) throws -> Data {
        var lastStatus: OSStatus = errSecSuccess
        for attempt in 0..<3 {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
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
            case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
                // Prompt-related: don't hammer the dialog, let the caller retry later.
                throw ConnectionError.accessDenied(tool: tool)
            default:
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
}
