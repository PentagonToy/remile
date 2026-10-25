import Foundation
import Security
import WebKit

/// Only this optional publisher window's cookies are saved, in the local login Keychain.
@MainActor final class ReferencePublisherIdentity: NSObject, WKHTTPCookieStoreObserver {
    static let preference = "reference.publisher.rememberSignIn"
    private let store: WKHTTPCookieStore
    private var pending: Task<Void, Never>?
    private var generation = UUID()
    private var observing = false
    private(set) var enabled: Bool
    var failure: (String) -> Void = { _ in }
    struct Saved: Codable {
        let date: Date
        let cookies: [Cookie]
    }
    struct Cookie: Codable {
        let name: String, value: String, domain: String, path: String
        let secure: Bool, httpOnly: Bool
        let expiry: Date?
        init(_ cookie: HTTPCookie) {
            name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path
            secure = cookie.isSecure; httpOnly = cookie.isHTTPOnly; expiry = cookie.expiresDate
        }
        var restored: HTTPCookie? {
            guard expiry.map({ $0 > Date() }) ?? true else { return nil }
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path, .secure: secure ? "TRUE" : "FALSE", HTTPCookiePropertyKey("HttpOnly"): httpOnly ? "TRUE" : "FALSE"]
            if let expiry { properties[.expires] = expiry }
            return HTTPCookie(properties: properties)
        }
    }
    nonisolated private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.remile.publisher.web", kSecAttrAccount as String: "publisher-access"]
    }
    init(store: WKHTTPCookieStore, enabled: Bool = UserDefaults.standard.bool(forKey: preference)) { self.store = store; self.enabled = enabled }
    static func encode(_ cookies: [HTTPCookie], now: Date = Date()) throws -> Data {
        let current = cookies.filter { $0.expiresDate.map { $0 > now } ?? true }
        guard current.count <= 512 else { throw ReferenceFailure("There is too much session data to remember.") }
        let data = try JSONEncoder().encode(Saved(date: now, cookies: current.map(Cookie.init)))
        guard data.count <= 256 * 1024 else { throw ReferenceFailure("There is too much session data to remember.") }
        return data
    }
    static func decode(_ data: Data, now: Date = Date()) throws -> [HTTPCookie] {
        guard data.count <= 256 * 1024 else { return [] }
        let saved = try JSONDecoder().decode(Saved.self, from: data)
        guard saved.cookies.count <= 512, saved.date <= now, now.timeIntervalSince(saved.date) <= 14 * 86400 else { return [] }
        return saved.cookies.compactMap(\.restored)
    }
    func restore() async {
        guard enabled else { return }
        let attempt = generation
        let result = await Task.detached {
            KeychainAccess.read(matching: Self.query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new }, interactive: false)
        }.value
        guard !Task.isCancelled, attempt == generation, enabled else { return }
        if result.status != errSecSuccess && result.status != errSecItemNotFound { failure("Saved sign-in is locked. You can sign in again."); return }
        if let bytes = result.data, let cookies = try? Self.decode(bytes) {
            for cookie in cookies {
                guard !Task.isCancelled, attempt == generation, enabled else { return }
                await store.setCookie(cookie)
            }
        }
        if !observing { store.add(self); observing = true }
    }
    func remember(_ value: Bool) {
        generation = UUID(); enabled = value; UserDefaults.standard.set(value, forKey: Self.preference)
        pending?.cancel(); pending = nil
        if value {
            if !observing { store.add(self); observing = true }
            cookiesDidChange(in: store)
        } else {
            if observing { store.remove(self); observing = false }
            let status = SecItemDelete(Self.query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { failure("Keychain could not remove the saved sign-in.") }
        }
    }
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        guard enabled else { return }
        pending?.cancel(); let attempt = generation
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            guard let self else { return }
            await self.save(attempt: attempt)
        }
    }
    private func save(attempt: UUID) async {
        let cookies = await store.allCookies()
        guard enabled, generation == attempt else { return }
        do {
            let data = try Self.encode(cookies)
            let status = KeychainAccess.store(data, matching: Self.query, attributes: [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly])
            if status != errSecSuccess { failure("Keychain could not remember this sign-in.") }
        } catch { failure(error.localizedDescription) }
    }
    func stop() {
        pending?.cancel(); pending = nil
        let wasObserving = observing
        if observing { store.remove(self); observing = false }
        guard enabled, wasObserving else { return }
        let attempt = generation
        // Finish a final bounded cookie snapshot, without retaining the browser window.
        Task { await save(attempt: attempt) }
    }
}
