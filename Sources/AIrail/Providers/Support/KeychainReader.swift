import Foundation
import Security

/// Read-only access to a generic-password item another tool created. macOS
/// puts up its own "AIrail wants to use your confidential information…"
/// dialog on first read; that dialog is the consent step, deliberately.
enum KeychainReader {
    static func genericPassword(service: String, tool: String) throws -> Data {
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
            guard let data = item as? Data else {
                throw ConnectionError.unreadable("empty Keychain item")
            }
            return data
        case errSecItemNotFound:
            throw ConnectionError.notSignedIn(tool: tool)
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            throw ConnectionError.accessDenied(tool: tool)
        default:
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw ConnectionError.unreadable(message)
        }
    }
}
