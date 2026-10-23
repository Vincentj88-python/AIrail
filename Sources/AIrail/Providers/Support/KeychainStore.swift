import Foundation
import Security

/// AIrail's own Keychain items — the only secrets it holds itself: API keys
/// the user pasted for platforms with a usage API, and its copy of a borrowed
/// sign-in's access token (so a relaunch doesn't ask macOS again). One
/// generic-password item per account, removed when the account is.
enum KeychainStore {
    static let service = "AIrail"

    static func set(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let query = baseQuery(account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrLabel as String] = "AIrail — \(account) API key"
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw ConnectionError.unreadable(message(for: status))
        }
    }

    static func get(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
        case errSecItemNotFound:
            return nil
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            throw ConnectionError.accessDenied(tool: "AIrail Keychain item")
        default:
            throw ConnectionError.unreadable(message(for: status))
        }
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    /// Reads one of AIrail's own items without ever showing a dialog: nil
    /// when it is missing, or when it was written by a build signed
    /// differently and macOS would ask (a copy is never worth a prompt).
    static func quietData(account: String) -> Data? {
        var query = baseQuery(account: account).merging(KeychainReader.noUI) { _, new in new }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Writes one of AIrail's own items without ever showing a dialog. An
    /// item this build can't update (another signature wrote it) is deleted
    /// and written again; if even that would need a dialog, nothing is kept.
    @discardableResult
    static func quietSet(_ data: Data, account: String, label: String) -> Bool {
        let query = baseQuery(account: account).merging(KeychainReader.noUI) { _, new in new }
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            SecItemDelete(query as CFDictionary)
            status = errSecItemNotFound
        }
        if status == errSecItemNotFound {
            var attributes = baseQuery(account: account)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrLabel as String] = label
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func message(for status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }
}
