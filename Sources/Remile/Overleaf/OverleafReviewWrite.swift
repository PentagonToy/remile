import Foundation
import WebKit

/// Changes review metadata through the editor's authenticated, CSRF-protected route.
@MainActor final class OverleafReviewWrite: NSObject, WKNavigationDelegate {
    private let web: WKWebView
    private let project: String
    private var ready: CheckedContinuation<Void, Error>?
    private var timer: Task<Void, Never>?
    private var loaded = false
    init(_ connection: OverleafConnection) {
        project = connection.projectID
        let config = WKWebViewConfiguration(); config.websiteDataStore = OverleafWebIdentity.dataStore(connection.profileID)
        config.preferences.inactiveSchedulingPolicy = .none
        web = WKWebView(frame: .zero, configuration: config)
        super.init(); web.navigationDelegate = self
    }
    func open() async throws {
        try OverleafReviewAccess.requireEnabled()
        try NetworkAccess.requireOnline(); try Task.checkCancellation()
        guard project.range(of: "^[a-f0-9]{24}$", options: .regularExpression) != nil else { throw OverleafSourceFiles.Failure.invalid }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                timer = Task { [weak self] in do { try await Task.sleep(for: .seconds(20)); self?.finish(OverleafGit.Failure("Overleaf did not confirm the review request. Try again.")) } catch { } }
                web.load(URLRequest(url: URL(string: "https://www.overleaf.com/project")!))
            }
        } onCancel: { Task { @MainActor [weak self] in self?.close() } }
    }
    func close() { finish(CancellationError()); web.stopLoading(); web.navigationDelegate = nil; web.loadHTMLString("", baseURL: nil); loaded = false }
    private func finish(_ error: Error? = nil) {
        timer?.cancel(); timer = nil
        guard let ready else { return }; self.ready = nil
        if let error { ready.resume(throwing: error) } else { loaded = true; ready.resume() }
    }
    private func request(_ action: String, args: [String: Any]) async throws -> [String: Any] {
        try OverleafReviewAccess.requireEnabled()
        try NetworkAccess.requireOnline(); try Task.checkCancellation()
        guard loaded else { throw OverleafGit.Failure("Reconnect review notes before trying again.") }
        let lease = try NetworkAccess.gate.watch { [weak self] in Task { @MainActor in self?.close() } }
        defer { NetworkAccess.gate.release(lease) }
        var args = args; args["action"] = action; args["project"] = project
        let value = try await web.callAsyncJavaScript(Self.script, arguments: args, in: nil, contentWorld: .page)
        try NetworkAccess.requireOnline(); try Task.checkCancellation()
        guard let result = value as? [String: Any], let status = result["status"] as? Int else { throw OverleafSourceFiles.Failure.uncertain }
        if status == 401 { throw OverleafWebClient.Failure.signIn }
        if status == 403 { throw OverleafWebClient.Failure.permission }
        if status == 429 { throw OverleafWebClient.Failure.rateLimited }
        guard (200...299).contains(status), result["success"] as? Bool != false else { throw OverleafSourceFiles.Failure.uncertain }
        return result
    }
    func acceptChange(document: String, change: String) async throws {
        guard Self.id(document), !change.isEmpty, change.utf8.count <= 256, !change.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw OverleafSourceFiles.Failure.invalid }
        _ = try await request("acceptChange", args: ["entity": document, "change": change])
    }
    private static func id(_ value: String) -> Bool { value.range(of: "^[a-f0-9]{24}$", options: .regularExpression) != nil }
    private static let script = """
    const csrf = document.querySelector('meta[name="ol-csrfToken"]')?.content;
    if (!csrf) return {status: 401};
    const response = await fetch('/project/' + project + '/doc/' + entity + '/changes/accept', {
        method: 'POST', credentials: 'same-origin', redirect: 'error', signal: AbortSignal.timeout(30000),
        headers: {'X-Csrf-Token': csrf, 'Accept': 'application/json', 'Content-Type': 'application/json'},
        body: JSON.stringify({change_ids: [change]})
    });
    return {status: response.status};
    """
    private func dashboard(_ url: URL?) -> Bool { url?.scheme == "https" && url?.host == "www.overleaf.com" && ["/project", "/project/"].contains(url?.path ?? "") && url?.port == nil }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !NetworkAccess.offline, dashboard(action.request.url) else { decisionHandler(.cancel); finish(OverleafWebClient.Failure.signIn); return }; decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { guard dashboard(web.url) else { finish(OverleafWebClient.Failure.signIn); return }; finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
}
