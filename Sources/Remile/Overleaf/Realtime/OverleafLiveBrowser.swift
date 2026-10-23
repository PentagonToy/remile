import Foundation
import WebKit

/// The account dashboard provides its permitted browser context to WebSocket.
/// It never loads a project editor or exports cookies to another browser/process.
@MainActor final class OverleafLiveBrowser: NSObject, WKNavigationDelegate {
    nonisolated let messages: AsyncThrowingStream<String, Error>
    private let output: AsyncThrowingStream<String, Error>.Continuation
    private let web: WKWebView
    private let project: String
    private var ready: CheckedContinuation<Void, Error>?
    private var timer: Task<Void, Never>?
    private var lease: UUID?
    private var active = false, started = false
    private static let page = URL(string: "https://www.overleaf.com/project")!
    private static func dashboard(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.host == "www.overleaf.com" && url.port == nil && url.user == nil && url.password == nil && ["/project", "/project/"].contains(url.path) && url.query == nil
    }
    private final class Receiver: NSObject, WKScriptMessageHandler {
        weak var owner: OverleafLiveBrowser?
        init(_ owner: OverleafLiveBrowser) { self.owner = owner }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == "www.overleaf.com" else { return }
            owner?.receive(message.body)
        }
    }
    init(profile: UUID, project: String) {
        self.project = project
        let stream = AsyncThrowingStream<String, Error>.makeStream(bufferingPolicy: .bufferingOldest(1_000))
        messages = stream.stream; output = stream.continuation
        let config = WKWebViewConfiguration(); config.websiteDataStore = OverleafWebIdentity.dataStore(profile)
        // This transport has no visible view. Idle suspension would miss heartbeats.
        config.preferences.inactiveSchedulingPolicy = .none
        web = WKWebView(frame: .zero, configuration: config)
        super.init(); web.navigationDelegate = self
        config.userContentController.add(Receiver(self), name: "remileLive")
    }
    func open() async throws {
        try NetworkAccess.requireOnline(); try Task.checkCancellation()
        guard !active else { throw OverleafLiveWire.Failure.protocolMismatch }
        active = true
        lease = try NetworkAccess.gate.watch { [weak self] in Task { @MainActor in self?.stop() } }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                timer = Task { [weak self] in do { try await Task.sleep(for: .seconds(20)); self?.finish(OverleafLiveWire.Failure.timeout) } catch { } }
                web.load(URLRequest(url: Self.page))
            }
        } onCancel: { Task { @MainActor [weak self] in self?.stop() } }
    }
    func send(_ frame: String) async throws {
        try NetworkAccess.requireOnline(); try Task.checkCancellation()
        guard active else { throw OverleafLiveWire.Failure.disconnected }
        _ = try await web.callAsyncJavaScript("if (!window.__remileLiveSocket || window.__remileLiveSocket.readyState !== WebSocket.OPEN) throw new Error('closed'); window.__remileLiveSocket.send(frame);", arguments: ["frame": frame], in: nil, contentWorld: .page)
    }
    func stop() { finish(CancellationError()) }
    private func finish(_ error: Error) {
        guard active else { return }; active = false
        timer?.cancel(); timer = nil; ready?.resume(throwing: error); ready = nil
        output.finish(throwing: error)
        web.configuration.preferences.inactiveSchedulingPolicy = .suspend
        web.evaluateJavaScript("window.__remileLiveSocket?.close(); window.__remileLiveSocket = null;")
        web.stopLoading(); web.navigationDelegate = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "remileLive")
        web.loadHTMLString("", baseURL: nil)
        if let lease { NetworkAccess.gate.release(lease); self.lease = nil }
    }
    private func receive(_ body: Any) {
        guard active, let value = body as? [String: Any], let type = value["type"] as? String else { return }
        switch type {
        case "stage":
            let allowed = ["fetch", "handshake", "upgrade", "handshake-format", "wire"]
            if let stage = value["stage"] as? String, allowed.contains(stage) { OverleafLiveDiagnostics.note(stage, code: value["status"] as? Int) }
        case "open": OverleafLiveDiagnostics.note("socket-open"); timer?.cancel(); timer = nil; ready?.resume(); ready = nil
        case "frame":
            guard let frame = value["frame"] as? String, frame.utf8.count <= OverleafLiveWire.frameLimit else { finish(OverleafLiveWire.Failure.protocolMismatch); return }
            if case .dropped = output.yield(frame) { finish(OverleafLiveWire.Failure.protocolMismatch) }
        case "handshake": finish(OverleafLiveWire.Failure.handshake((value["status"] as? Int) ?? 0))
        case "closed": OverleafLiveDiagnostics.note("socket-closed", code: value["code"] as? Int); finish(OverleafLiveWire.Failure.disconnected)
        default: finish(OverleafLiveWire.Failure.protocolMismatch)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame == false {
            decisionHandler(active && !NetworkAccess.offline && action.request.url?.scheme == "https" ? .allow : .cancel); return
        }
        guard active, !NetworkAccess.offline, Self.dashboard(action.request.url) else {
            decisionHandler(.cancel); if active { finish(OverleafLiveWire.Failure.authentication) }; return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !response.isForMainFrame {
            decisionHandler(active && !NetworkAccess.offline && response.response.url?.scheme == "https" ? .allow : .cancel); return
        }
        guard active, response.isForMainFrame, let http = response.response as? HTTPURLResponse, Self.dashboard(http.url),
              http.statusCode == 200, http.mimeType == "text/html" else {
            decisionHandler(.cancel); finish(OverleafLiveWire.Failure.authentication); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard active, !started, Self.dashboard(webView.url) else { return }; started = true
        web.callAsyncJavaScript(Self.bootstrap, arguments: ["project": project], in: nil, in: .page) { [weak self] result in
            if case .failure(let error) = result { OverleafLiveDiagnostics.note("bootstrap-error", code: (error as NSError).code); self?.finish(OverleafLiveWire.Failure.protocolMismatch) }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if active { finish(error) } }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if active { finish(error) } }
    private static let bootstrap = """
    const post = value => window.webkit.messageHandlers.remileLive.postMessage(value);
    const query = new URLSearchParams({projectId: project, t: String(Date.now())});
    post({type: 'stage', stage: 'fetch'});
    const response = await fetch('/socket.io/1/?' + query, {credentials: 'include', redirect: 'error', cache: 'no-store'});
    post({type: 'stage', stage: 'handshake', status: response.status});
    if (response.status !== 200) { post({type: 'handshake', status: response.status}); return; }
    const body = await response.text();
    const parts = body.split(':');
    if (body.length > 4096 || parts.length !== 4 || !/^[A-Za-z0-9_-]{1,200}$/.test(parts[0]) || !parts[3].split(',').includes('websocket')) { post({type: 'stage', stage: 'handshake-format', status: parts.length}); post({type: 'invalid'}); return; }
    post({type: 'stage', stage: 'upgrade'});
    const socket = new WebSocket('wss://www.overleaf.com/socket.io/1/websocket/' + parts[0] + '?' + query);
    window.__remileLiveSocket = socket;
    socket.onopen = () => post({type: 'open'});
    socket.onmessage = event => { if (typeof event.data !== 'string' || event.data.length > 8000000) { socket.close(); post({type: 'invalid'}); } else post({type: 'frame', frame: event.data}); };
    socket.onerror = () => { post({type: 'stage', stage: 'wire'}); post({type: 'invalid'}); };
    socket.onclose = event => post({type: 'closed', code: event.code});
    """
    deinit { if let lease { NetworkAccess.gate.release(lease) }; output.finish() }
}
