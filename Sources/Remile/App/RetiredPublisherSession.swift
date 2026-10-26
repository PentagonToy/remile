import Foundation
import Security

/// Retire only the removed publisher feature's own cookie backup. Never read credentials.
enum RetiredPublisherSession {
    private static let completed = "migration.publisherSessionRemoved.v1"
    static func clear(defaults: UserDefaults = .standard, remove: ([String: Any]) -> OSStatus = { KeychainAccess.remove(matching: $0) }) {
        defaults.removeObject(forKey: "reference.publisher.rememberSignIn")
        guard !defaults.bool(forKey: completed) else { return }
        let status = remove([kSecClass as String: kSecClassGenericPassword,
                             kSecAttrService as String: "local.remile.publisher.web",
                             kSecAttrAccount as String: "publisher-access"])
        // A locked item waits for another launch. No prompt or background retry loop.
        if status == errSecSuccess || status == errSecItemNotFound { defaults.set(true, forKey: completed) }
    }
}
