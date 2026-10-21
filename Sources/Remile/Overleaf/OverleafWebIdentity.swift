import Foundation
import WebKit
import Security

/// Session cookies belong to remile.'s account, never another browser's store.
@MainActor enum OverleafWebIdentity {
    private static var restored = Set<UUID>()
    private struct Cookie: Codable {
        let name: String, value: String, domain: String, path: String
        let secure: Bool, httpOnly: Bool
        let expiry: Date?
        init(_ cookie: HTTPCookie) { name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path; secure = cookie.isSecure; httpOnly = cookie.isHTTPOnly; expiry = cookie.expiresDate }
        var cookie: HTTPCookie? {
            guard expiry.map({ $0 > Date() }) ?? true else { return nil }
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path, .secure: secure ? "TRUE" : "FALSE", HTTPCookiePropertyKey("HttpOnly"): httpOnly ? "TRUE" : "FALSE"]
            if let expiry { properties[.expires] = expiry }
            return HTTPCookie(properties: properties)
        }
    }
    private static func query(_ id: UUID) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.remile.overleaf.web", kSecAttrAccount as String: id.uuidString] }
    static func remember(_ id: UUID) async {
        let cookies = await WKWebsiteDataStore(forIdentifier: id).httpCookieStore.allCookies().filter { $0.domain == ".overleaf.com" || $0.domain == "overleaf.com" || $0.domain == "www.overleaf.com" || $0.domain == ".www.overleaf.com" }
        guard !cookies.isEmpty, let bytes = try? JSONEncoder().encode(cookies.map(Cookie.init)) else { return }
        let attributes: [String: Any] = [kSecValueData as String: bytes, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemAdd(query(id).merging(attributes) { _, new in new } as CFDictionary, nil)
        if result == errSecDuplicateItem { SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary) }
    }
    static func restore(_ id: UUID) async {
        guard restored.insert(id).inserted else { return }
        let store = WKWebsiteDataStore(forIdentifier: id).httpCookieStore
        let existing = await store.allCookies()
        // A current signed-in session takes precedence over an older saved session.
        if existing.contains(where: { ["overleaf_session2", "overleaf.sid", "sharelatex.sid"].contains($0.name) }) { return }
        var item: CFTypeRef?
        let request = query(id).merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new }
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let bytes = item as? Data, let saved = try? JSONDecoder().decode([Cookie].self, from: bytes) else { return }
        for cookie in saved.compactMap(\.cookie) { await store.setCookie(cookie) }
    }
}

/// Some account endpoints require WebKit's existing verified session context.
/// This loads JSON only; it never mounts a project editor or presence socket.
@MainActor final class OverleafJSONRequest: NSObject, WKNavigationDelegate {
    private let web: WKWebView
    private let url: URL
    private var result: CheckedContinuation<Data, Error>?
    private var timer: Task<Void, Never>?
    init(url: URL, profile: UUID) {
        self.url = url
        let config = WKWebViewConfiguration(); config.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile)
        web = WKWebView(frame: .zero, configuration: config)
        super.init(); web.navigationDelegate = self
    }
    func load() async throws -> Data {
        try NetworkAccess.requireOnline()
        let lease = try NetworkAccess.gate.watch { [weak self] in Task { @MainActor in
            self?.web.stopLoading(); self?.web.navigationDelegate = nil; self?.web.loadHTMLString("", baseURL: nil); self?.finish(.failure(NetworkAccessGate.Offline()))
        } }; defer { NetworkAccess.gate.release(lease) }
        defer { timer?.cancel(); web.stopLoading(); web.navigationDelegate = nil }
        return try await withCheckedThrowingContinuation { result in
            self.result = result
            timer = Task { [weak self] in do { try await Task.sleep(for: .seconds(30)); self?.finish(.failure(OverleafWebClient.Failure.response)) } catch { } }
            web.load(URLRequest(url: url))
        }
    }
    private func finish(_ value: Result<Data, Error>) { guard let result else { return }; self.result = nil; result.resume(with: value) }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !NetworkAccess.offline, action.request.url == url else { decisionHandler(.cancel); finish(.failure(OverleafWebClient.Failure.signIn)); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let http = response.response as? HTTPURLResponse, http.statusCode == 200, http.value(forHTTPHeaderField: "Content-Type")?.contains("json") == true else { decisionHandler(.cancel); finish(.failure(OverleafWebClient.Failure.signIn)); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        web.evaluateJavaScript("document.body.textContent") { [weak self] text, _ in
            guard let self else { return }
            guard let text = text as? String, text.utf8.count <= 8_000_000, let data = text.data(using: .utf8) else { self.finish(.failure(OverleafWebClient.Failure.response)); return }
            self.finish(.success(data))
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(OverleafWebClient.Failure.response)) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(OverleafWebClient.Failure.response)) }
}
