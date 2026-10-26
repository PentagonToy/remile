import Foundation
import WebKit
import Security
import CryptoKit

/// Session cookies belong to remile.'s account, never another browser's store.
@MainActor enum OverleafWebIdentity {
    private static var revoked = Set<UUID>()
    private static var stores: [UUID: WKWebsiteDataStore] = [:]
    static func dataStore(_ id: UUID) -> WKWebsiteDataStore {
        if revoked.contains(id) { return .nonPersistent() }
        if let store = stores[id] { return store }
        let store = WKWebsiteDataStore(forIdentifier: id); stores[id] = store; return store
    }
    private static let access = OverleafSessionAccess()
    private static var savedDigests: [UUID: SHA256.Digest] = [:]
    private static var saveRetryAfter: [UUID: Date] = [:]
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
    nonisolated private static func query(_ id: UUID) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.remile.overleaf.web", kSecAttrAccount as String: id.uuidString] }
    nonisolated static func isUsable(_ cookie: HTTPCookie, now: Date = Date()) -> Bool {
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        return ["overleaf.com", "www.overleaf.com"].contains(domain.lowercased()) && (cookie.expiresDate.map { $0 > now } ?? true)
    }
    @discardableResult static func remember(_ id: UUID) async -> Bool {
        guard !revoked.contains(id) else { return false }
        let cookies = await OverleafWebIdentity.dataStore(id).httpCookieStore.allCookies().filter { isUsable($0) }.sorted { ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name) }
        guard !revoked.contains(id) else { return false }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard !cookies.isEmpty, let bytes = try? encoder.encode(cookies.map(Cookie.init)) else { return false }
        let digest = SHA256.hash(data: bytes)
        if savedDigests[id].map({ Array($0) == Array(digest) }) == true { return true }
        if let retry = saveRetryAfter[id], Date() < retry { return false }
        let result = KeychainAccess.store(bytes, matching: query(id), attributes: [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly])
        if result == errSecSuccess { savedDigests[id] = digest; saveRetryAfter[id] = nil; return true }
        saveRetryAfter[id] = Date().addingTimeInterval(30)
        return false
    }
    static func forget(_ id: UUID) async throws {
        let store = dataStore(id)
        revoked.insert(id); access.forget(id)
        let result = SecItemDelete(query(id) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { revoked.remove(id); throw OverleafWebClient.Failure.sessionLocked }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        stores[id] = nil; savedDigests[id] = nil; saveRetryAfter[id] = nil
    }
    static func restore(_ id: UUID, interactive: Bool = false) async throws {
        guard !revoked.contains(id) else { throw OverleafWebClient.Failure.signIn }
        let store = OverleafWebIdentity.dataStore(id).httpCookieStore
        let existing = await store.allCookies()
        // A current signed-in session takes precedence over an older saved session.
        if !interactive, existing.contains(where: { isUsable($0) && ["overleaf_session2", "overleaf.sid", "sharelatex.sid"].contains($0.name) }) { return }
        try await access.restore(id, interactive: interactive) { try await restoreSaved(id, interactive: interactive) }
    }
    private static func restoreSaved(_ id: UUID, interactive: Bool) async throws {
        let store = OverleafWebIdentity.dataStore(id).httpCookieStore
        let result = await Task.detached {
            let request = query(id).merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new }
            return KeychainAccess.read(matching: request, interactive: interactive)
        }.value
        guard result.status == errSecSuccess else {
            if result.status == errSecItemNotFound { return }
            if [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable, errSecUserCanceled].contains(result.status) { throw OverleafWebClient.Failure.sessionLocked }
            throw OverleafWebClient.Failure.response
        }
        guard let bytes = result.data, let saved = try? JSONDecoder().decode([Cookie].self, from: bytes) else { return }
        try Task.checkCancellation()
        for cookie in saved.compactMap(\.cookie) where isUsable(cookie) { await store.setCookie(cookie) }
        if interactive { saveRetryAfter[id] = nil }
    }
}

/// Some account endpoints require WebKit's existing verified session context.
/// This loads JSON only. It never mounts a project editor or presence socket.
@MainActor final class OverleafJSONRequest: NSObject, WKNavigationDelegate {
    private let web: WKWebView
    private let url: URL
    private let document: Bool
    private var navigationURL: URL { document ? URL(string: "https://www.overleaf.com/project")! : url }
    private var result: CheckedContinuation<Data, Error>?
    private var timer: Task<Void, Never>?
    init(url: URL, profile: UUID, document: Bool = false) {
        self.document = document
        self.url = url
        let config = WKWebViewConfiguration(); config.websiteDataStore = OverleafWebIdentity.dataStore(profile)
        web = WKWebView(frame: .zero, configuration: config)
        super.init(); web.navigationDelegate = self
    }
    func load() async throws -> Data {
        try NetworkAccess.requireOnline()
        let lease = try NetworkAccess.gate.watch { [weak self] in Task { @MainActor in
            self?.web.stopLoading(); self?.web.navigationDelegate = nil; self?.web.loadHTMLString("", baseURL: nil); self?.finish(.failure(NetworkAccessGate.Offline()))
        } }; defer { NetworkAccess.gate.release(lease) }
        defer { timer?.cancel(); web.stopLoading(); web.navigationDelegate = nil }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { result in
                self.result = result
                timer = Task { [weak self] in do { try await Task.sleep(for: .seconds(30)); self?.finish(.failure(OverleafWebClient.Failure.response)) } catch { } }
                web.load(URLRequest(url: navigationURL))
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } }
    }
    private func finish(_ value: Result<Data, Error>) { guard let result else { return }; self.result = nil; result.resume(with: value) }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !NetworkAccess.offline else { decisionHandler(.cancel); finish(.failure(NetworkAccessGate.Offline())); return }
        guard action.request.url == navigationURL else {
            decisionHandler(.cancel)
            let failure: OverleafWebClient.Failure = action.request.url.map(OverleafWebClient.isLoginURL) == true ? .signIn : .response
            finish(.failure(failure)); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let http = response.response as? HTTPURLResponse else { decisionHandler(.cancel); finish(.failure(OverleafWebClient.Failure.response)); return }
        if document {
            guard http.statusCode == 200, http.mimeType?.lowercased() == "text/html" else { decisionHandler(.cancel); finish(.failure(OverleafWebClient.Failure.response)); return }
        } else if let failure = OverleafWebClient.responseFailure(http) { decisionHandler(.cancel); finish(.failure(failure)); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if document {
            web.callAsyncJavaScript("""
                const response = await fetch(path, {credentials: 'same-origin', redirect: 'error'});
                const type = (response.headers.get('content-type') || '').split(';')[0].toLowerCase();
                if (response.status !== 200 || !['text/plain', 'application/x-tex', 'application/octet-stream'].includes(type)) return {status: response.status};
                const reader = response.body.getReader();
                const decoder = new TextDecoder('utf-8', {fatal: true});
                let text = '', count = 0;
                while (true) {
                    const {value, done} = await reader.read();
                    if (done) break;
                    count += value.byteLength;
                    if (count > 8000000) { await reader.cancel(); throw new Error('Document too large'); }
                    text += decoder.decode(value, {stream: true});
                }
                text += decoder.decode();
                return {status: 200, text, disposition: response.headers.get('content-disposition') || ''};
                """, arguments: ["path": url.path], in: nil, in: .defaultClient) { [weak self] result in
                    guard let self else { return }
                    guard case .success(let raw) = result, let value = raw as? [String: Any], let status = value["status"] as? Int else { self.finish(.failure(OverleafWebClient.Failure.response)); return }
                    guard status == 200, value["text"] is String, let data = try? JSONSerialization.data(withJSONObject: value) else {
                        self.finish(.failure(status == 401 ? OverleafWebClient.Failure.signIn : status == 403 ? .permission : .response)); return
                    }
                    self.finish(.success(data))
                }
            return
        }
        web.evaluateJavaScript("document.body.textContent") { [weak self] text, _ in
            guard let self else { return }
            guard let text = text as? String, text.utf8.count <= 8_000_000, let data = text.data(using: .utf8) else { self.finish(.failure(OverleafWebClient.Failure.response)); return }
            self.finish(.success(data))
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(OverleafWebClient.Failure.response)) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(OverleafWebClient.Failure.response)) }
}
