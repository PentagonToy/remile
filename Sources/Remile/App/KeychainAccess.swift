import Foundation
import Security
import LocalAuthentication

/// Serialises reads of the existing login-keychain items. LAContext alone does not
/// suppress classic keychain approval dialogs. Silent reads temporarily disable
/// optional interaction for this process, restore its prior state, and fail closed.
enum KeychainAccess {
    private static let lock = NSLock()
    static func data(matching query: [String: Any], interactive: Bool) -> Data? {
        read(matching: query, interactive: interactive).data
    }
    static func read(matching query: [String: Any], interactive: Bool) -> (status: OSStatus, data: Data?) {
        perform(interactive: interactive) {
            var query = query
            if !interactive { let context = LAContext(); context.interactionNotAllowed = true; query[kSecUseAuthenticationContext as String] = context }
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            return (status, item as? Data)
        }
    }
    static func store(_ data: Data, matching query: [String: Any], attributes: [String: Any]) -> OSStatus {
        perform(interactive: false) {
            let values = attributes.merging([kSecValueData as String: data]) { _, new in new }
            let status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
            return (status == errSecDuplicateItem ? SecItemUpdate(query as CFDictionary, values as CFDictionary) : status, nil)
        }.status
    }
    private static func perform(interactive: Bool, operation: () -> (status: OSStatus, data: Data?)) -> (status: OSStatus, data: Data?) {
        lock.lock(); defer { lock.unlock() }
        var previous = DarwinBoolean(true)
        if !interactive {
            guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
                  SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { return (errSecInteractionNotAllowed, nil) }
        }
        defer { if !interactive { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) } }
        return operation()
    }
}
