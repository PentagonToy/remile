import AppKit
import WebKit

@MainActor
final class WordArt: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var window: NSWindow?
    private var continuation: CheckedContinuation<NSImage, Error>?
    private var deadline: Task<Void, Never>?
    private var task: Task<Void, Never>?
    static func image(_ markup: String) async throws -> NSImage {
        let renderer = WordArt()
        return try await renderer.load(markup)
    }
    private func load(_ markup: String) async throws -> NSImage {
        try Task.checkCancellation()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 2000, height: 2000), configuration: configuration)
        self.web = web; web.navigationDelegate = self
        let host = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false; host.contentView = web; window = host
        let html = "<html><head><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; script-src 'none'; img-src data:;\"><style>html,body{margin:0;background:white;color:black;}#art{display:inline-block;padding:4px;font:16px 'Times New Roman';}math{font-size:16px;}</style></head><body><span id=\"art\">" + markup + "</span></body></html>"
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                deadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(25)); self?.finish(.failure(WordImages.Failure.feature("Word artwork rendering timed out."))) } catch { }
                }
                web.loadHTMLString(html, baseURL: nil)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType == .other && navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard task == nil, continuation != nil else { return }
        task = Task { @MainActor in
            do {
                guard let size = try await webView.evaluateJavaScript("(()=>{const r=document.getElementById('art').getBoundingClientRect();return [r.width,r.height]})()") as? [Double], size.count == 2, size.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1900 }) else { throw WordImages.Failure.unsupported }
                let configuration = WKPDFConfiguration(); configuration.rect = CGRect(x: 0, y: 0, width: ceil(size[0]), height: ceil(size[1]))
                let data: Data = try await withCheckedThrowingContinuation { continuation in webView.createPDF(configuration: configuration) { continuation.resume(with: $0) } }
                try Task.checkCancellation()
                guard let image = NSImage(data: data) else { throw WordImages.Failure.unsupported }
                image.size = NSSize(width: ceil(size[0]) * 0.75, height: ceil(size[1]) * 0.75)
                finish(.success(image))
            } catch { finish(.failure(error)) }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(WordImages.Failure.unsupported)) }
    private func finish(_ result: Result<NSImage, Error>) {
        guard let continuation else { return }
        self.continuation = nil; deadline?.cancel(); deadline = nil; task?.cancel(); task = nil
        web?.navigationDelegate = nil; web?.stopLoading(); window?.contentView = nil; window?.close(); window = nil; web = nil
        continuation.resume(with: result)
    }
}
