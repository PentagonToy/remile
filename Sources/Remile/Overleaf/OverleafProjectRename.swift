import Foundation
import WebKit

/// An explicit metadata write through remile's own signed-in web profile.
@MainActor final class OverleafProjectRename: NSObject, WKNavigationDelegate {
    enum Failure: LocalizedError {
        case unavailable, name, signIn, permission, response
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Connect to Overleaf and finish the current operation first."
            case .name: return "Use a project name up to 150 characters."
            case .signIn: return "Sign in to Overleaf to rename this project."
            case .permission: return "Check your Overleaf sign-in and permission to rename this project."
            case .response: return "Overleaf did not confirm the rename. Check the site before trying again."
            }
        }
    }
    static func path(projectID: String, name: String) throws -> String {
        guard projectID.range(of: "^[a-fA-F0-9]{24}$", options: .regularExpression) != nil else { throw Failure.unavailable }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf16.count <= 150, name.rangeOfCharacter(from: .controlCharacters) == nil else { throw Failure.name }
        return "/project/" + projectID + "/rename"
    }
    static let script = """
    const token = document.querySelector('meta[name="ol-csrfToken"]')?.content;
    if (!token) return 401;
    const response = await fetch(renamePath, {
        method: 'POST', credentials: 'same-origin', redirect: 'error',
        headers: { 'Content-Type': 'application/json', 'Accept': 'application/json', 'X-Csrf-Token': token },
        body: JSON.stringify({ newProjectName })
    });
    return response.status;
    """
    static func rename(_ connection: OverleafConnection, to name: String) async throws {
        let path = try path(projectID: connection.projectID, name: name)
        try await OverleafWebIdentity.restore(connection.profileID)
        let request = OverleafProjectRename(profile: connection.profileID, path: path, name: name)
        try await request.perform()
        await OverleafWebIdentity.remember(connection.profileID)
    }
    private let web: WKWebView
    private let path: String, name: String
    private var result: CheckedContinuation<Void, Error>?
    private var timer: Task<Void, Never>?
    private var started = false
    private init(profile: UUID, path: String, name: String) {
        self.path = path; self.name = name
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile)
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init(); web.navigationDelegate = self
    }
    private func perform() async throws {
        try NetworkAccess.requireOnline()
        let lease = try NetworkAccess.gate.watch { [weak self] in Task { @MainActor in
            self?.web.stopLoading(); self?.web.navigationDelegate = nil; self?.web.loadHTMLString("", baseURL: nil); self?.finish(.failure(NetworkAccessGate.Offline()))
        } }; defer { NetworkAccess.gate.release(lease) }
        defer { timer?.cancel(); web.stopLoading(); web.navigationDelegate = nil }
        try await withCheckedThrowingContinuation { result in
            self.result = result
            timer = Task { [weak self] in do { try await Task.sleep(for: .seconds(30)); self?.finish(.failure(Failure.response)) } catch { } }
            web.load(URLRequest(url: URL(string: "https://www.overleaf.com/project")!))
        }
    }
    private func finish(_ value: Result<Void, Error>) { guard let result else { return }; self.result = nil; result.resume(with: value) }
    private func dashboard(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && ["overleaf.com", "www.overleaf.com"].contains(url.host) && ["/project", "/project/"].contains(url.path) && url.port == nil && url.user == nil && url.password == nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !NetworkAccess.offline, action.targetFrame?.isMainFrame == true else { decisionHandler(.cancel); return }
        guard dashboard(action.request.url) else { decisionHandler(.cancel); finish(.failure(Failure.signIn)); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard response.isForMainFrame, dashboard(response.response.url), (response.response as? HTTPURLResponse)?.statusCode == 200 else { decisionHandler(.cancel); finish(.failure(Failure.signIn)); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !NetworkAccess.offline, result != nil, !started, dashboard(web.url) else { return }; started = true
        web.callAsyncJavaScript(Self.script, arguments: ["renamePath": path, "newProjectName": name], in: nil, in: .page) { [weak self] response in
            guard let self else { return }
            switch response {
            case .success(let value):
                switch (value as? NSNumber)?.intValue {
                case 200, 204: self.finish(.success(()))
                case 401: self.finish(.failure(Failure.signIn))
                case 403: self.finish(.failure(Failure.permission))
                default: self.finish(.failure(Failure.response))
                }
            case .failure: self.finish(.failure(Failure.response))
            }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(Failure.response)) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(Failure.response)) }
}
