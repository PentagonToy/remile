import Foundation
import WebKit

/// Uses the same authenticated, CSRF-protected file routes as the Overleaf editor.
@MainActor final class OverleafFileService: NSObject, WKNavigationDelegate {
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
        try NetworkAccess.requireOnline(); try Task.checkCancellation()
        guard project.range(of: "^[a-f0-9]{24}$", options: .regularExpression) != nil else { throw OverleafLiveFiles.Failure.invalid }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                timer = Task { [weak self] in do { try await Task.sleep(for: .seconds(20)); self?.finish(OverleafLiveWire.Failure.timeout) } catch { } }
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
        try NetworkAccess.requireOnline(); try Task.checkCancellation()
        guard loaded else { throw OverleafLiveWire.Failure.disconnected }
        let lease = try NetworkAccess.gate.watch { [weak self] in Task { @MainActor in self?.close() } }
        defer { NetworkAccess.gate.release(lease) }
        var args = args; args["action"] = action; args["project"] = project
        let value = try await web.callAsyncJavaScript(Self.script, arguments: args, in: nil, contentWorld: .page)
        try NetworkAccess.requireOnline(); try Task.checkCancellation()
        guard let result = value as? [String: Any], let status = result["status"] as? Int else { throw OverleafLiveFiles.Failure.uncertain }
        if status == 401 { throw OverleafWebClient.Failure.signIn }
        if status == 403 { throw OverleafWebClient.Failure.permission }
        if status == 429 { throw OverleafWebClient.Failure.rateLimited }
        guard (200...299).contains(status), result["success"] as? Bool != false else { throw OverleafLiveFiles.Failure.uncertain }
        return result
    }
    func upload(_ bytes: Data, path: String, root: String) async throws -> OverleafLiveFiles.Entry {
        guard OverleafLiveFiles.validPath(path), bytes.count <= OverleafLiveFiles.fileLimit, Self.id(root) else { throw OverleafLiveFiles.Failure.invalid }
        let result = try await request("upload", args: ["path": path, "root": root, "encoded": bytes.base64EncodedString()])
        guard let id = result["entity_id"] as? String, Self.id(id), let kind = result["entity_type"] as? String, ["file", "doc"].contains(kind) else { throw OverleafLiveFiles.Failure.uncertain }
        return .init(id: id, kind: kind, path: path)
    }
    func rename(_ entry: OverleafLiveFiles.Entry, name: String) async throws {
        guard Self.id(entry.id), ["doc", "file"].contains(entry.kind), OverleafLiveFiles.validPath(name), !name.contains("/") else { throw OverleafLiveFiles.Failure.invalid }
        _ = try await request("rename", args: ["entity": entry.id, "kind": entry.kind, "name": name])
    }
    func delete(_ entry: OverleafLiveFiles.Entry) async throws {
        guard Self.id(entry.id), ["doc", "file"].contains(entry.kind) else { throw OverleafLiveFiles.Failure.invalid }
        _ = try await request("delete", args: ["entity": entry.id, "kind": entry.kind])
    }
    func acceptChange(document: String, change: String) async throws {
        guard Self.id(document), !change.isEmpty, change.utf8.count <= 256, !change.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw OverleafLiveFiles.Failure.invalid }
        _ = try await request("acceptChange", args: ["entity": document, "change": change])
    }
    private static func id(_ value: String) -> Bool { value.range(of: "^[a-f0-9]{24}$", options: .regularExpression) != nil }
    private static let script = """
    const csrf = document.querySelector('meta[name="ol-csrfToken"]')?.content;
    if (!csrf) return {status: 401};
    let url, method, body, headers = {'X-Csrf-Token': csrf, 'Accept': 'application/json'};
    if (action === 'upload') {
        const raw = atob(encoded), bytes = new Uint8Array(raw.length);
        for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
        const name = path.split('/').pop();
        body = new FormData(); body.append('name', name); body.append('relativePath', path);
        body.append('qqfile', new Blob([bytes], {type: 'application/octet-stream'}), name);
        url = '/Project/' + project + '/upload?folder_id=' + root; method = 'POST';
    } else if (action === 'acceptChange') {
        url = '/project/' + project + '/doc/' + entity + '/changes/accept';
        method = 'POST'; headers['Content-Type'] = 'application/json'; body = JSON.stringify({change_ids: [change]});
    } else {
        url = '/project/' + project + '/' + kind + '/' + entity;
        if (action === 'rename') { url += '/rename'; method = 'POST'; headers['Content-Type'] = 'application/json'; body = JSON.stringify({name}); }
        else if (action === 'delete') { method = 'DELETE'; }
        else throw new Error('unsupported');
    }
    const response = await fetch(url, {method, body, headers, credentials: 'same-origin', redirect: 'error', signal: AbortSignal.timeout(45000)});
    let result = {}; if (action === 'upload' && response.ok) result = await response.json();
    return {...result, status: response.status};
    """
    private func dashboard(_ url: URL?) -> Bool { url?.scheme == "https" && url?.host == "www.overleaf.com" && ["/project", "/project/"].contains(url?.path ?? "") && url?.port == nil }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !NetworkAccess.offline, dashboard(action.request.url) else { decisionHandler(.cancel); finish(OverleafWebClient.Failure.signIn); return }; decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { guard dashboard(web.url) else { finish(OverleafWebClient.Failure.signIn); return }; finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
}
