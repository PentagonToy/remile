import Foundation
import Security
import LocalAuthentication

/// Serialises reads of the existing login-keychain items. LAContext alone does not
/// suppress classic keychain approval dialogs. Silent reads temporarily disable
/// optional interaction for this process, restore its prior state, and fail closed.
enum KeychainAccess {
    private static let lock = NSLock()
    static func data(matching query: [String: Any], interactive: Bool) -> Data? {
        lock.lock(); defer { lock.unlock() }
        var previous = DarwinBoolean(true)
        if !interactive {
            guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
                  SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { return nil }
        }
        defer { if !interactive { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) } }
        var query = query
        if !interactive { let context = LAContext(); context.interactionNotAllowed = true; query[kSecUseAuthenticationContext as String] = context }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
}
