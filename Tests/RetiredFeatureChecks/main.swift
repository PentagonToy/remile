import Foundation
import Security

let suite = "remile.retired-feature-test." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
var checks = 0, calls = 0
func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
defaults.set(true, forKey: "reference.publisher.rememberSignIn")
defaults.set("preserved", forKey: "overleaf.testAccount")
RetiredPublisherSession.clear(defaults: defaults) { query in
    calls += 1
    check(query.count == 3, "Deletion is scoped, without credential data or wildcard accounts")
    check(query[kSecClass as String] as? String == kSecClassGenericPassword as String, "Generic password items only")
    check(query[kSecAttrService as String] as? String == "local.remile.publisher.web", "Only the retired service")
    check(query[kSecAttrAccount as String] as? String == "publisher-access", "Only its own account")
    return errSecInteractionNotAllowed
}
check(defaults.object(forKey: "reference.publisher.rememberSignIn") == nil, "Removed preference cannot restore a session")
check(defaults.string(forKey: "overleaf.testAccount") == "preserved", "Unrelated preferences remain")
RetiredPublisherSession.clear(defaults: defaults) { _ in calls += 1; return errSecItemNotFound }
check(calls == 2, "A locked cleanup can retry on the next launch")
RetiredPublisherSession.clear(defaults: defaults) { _ in fatalError("A completed cleanup must not run again") }
check(calls == 2, "Completed migration is idle")
defaults.removePersistentDomain(forName: suite)
RetiredPublisherSession.clear(defaults: defaults) { _ in calls += 1; return errSecSuccess }
RetiredPublisherSession.clear(defaults: defaults) { _ in fatalError("Successful removal is final") }
check(calls == 3, "Successful removal runs once")
print("Passed \(checks) retired-feature checks without accessing the real Keychain")
