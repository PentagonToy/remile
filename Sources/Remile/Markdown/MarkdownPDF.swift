import AppKit
import PDFKit
import WebKit

@MainActor
final class MarkdownPDF: NSObject, WKNavigationDelegate {
    enum Failure: LocalizedError {
        case rendering, timeout
        var errorDescription: String? { self == .timeout ? "Markdown rendering timed out." : "Unable to render Markdown." }
    }
    private var webView: WKWebView?
    private var window: NSWindow?
    private var continuation: CheckedContinuation<Void, Error>?
    private var deadline: Task<Void, Never>?
    private var output: URL?
    private var printing = false
    private var progress: (Double) -> Void = { _ in }
    private var exportTask: Task<Void, Never>?

    static func write(_ html: String, to output: URL, progress: @escaping (Double) -> Void = { _ in }) async throws {
        let renderer = MarkdownPDF()
        renderer.progress = progress
        try await renderer.render(html, to: output)
        try Task.checkCancellation()
    }
    private func render(_ html: String, to output: URL) async throws {
        try Task.checkCancellation()
        self.output = output
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true // Only our native DOM measurements run; CSP blocks authored scripts.
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 960), configuration: configuration)
        web.navigationDelegate = self
        webView = web
        let host = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false; host.contentView = web; window = host
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                deadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(40)); self?.finish(.failure(Failure.timeout)) } catch { }
                }
                web.loadHTMLString(html, baseURL: nil)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType == .other && navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard continuation != nil, !printing, let output else { return }
        printing = true
        exportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.export(webView, to: output); self.finish(.success(())) }
            catch { self.finish(.failure(error)) }
        }
    }
    private func export(_ web: WKWebView, to output: URL) async throws {
        let script = """
        (() => {
          const boxes = [];
          for (const e of document.querySelectorAll('tr,img,math,h1,h2,h3,h4')) {
            const r = e.getBoundingClientRect(); boxes.push({top:r.top,bottom:r.bottom});
          }
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          let node;
          while (node = walker.nextNode()) {
            if (!node.textContent.trim()) continue;
            const range = document.createRange(); range.selectNodeContents(node);
            for (const r of range.getClientRects()) boxes.push({top:r.top,bottom:r.bottom});
          }
          return {height: Math.max(document.body.scrollHeight,document.documentElement.scrollHeight), boxes};
        })()
        """
        guard let metrics = try await web.evaluateJavaScript(script) as? [String: Any], let height = metrics["height"] as? Double else { throw Failure.rendering }
        let boxes = metrics["boxes"] as? [[String: Double]] ?? []
        guard height > 0, height <= 960_000 else { throw Failure.rendering }
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(output as CFURL, mediaBox: &media, nil) else { throw Failure.rendering }
        defer { context.closePDF() }
        var start = 0.0, count = 0
        while start < height - 0.5 {
            try Task.checkCancellation()
            guard count < 1000 else { throw Failure.rendering }
            var end = min(start + 960, height)
            if end < height {
                // Move a cut above crossing text lines, table rows, images and formulas.
                for _ in 0..<8 {
                    let previous = end
                    for box in boxes {
                        guard let top = box["top"], let bottom = box["bottom"], top > start + 1, top < end, bottom > end + 0.1, bottom - top <= 960 else { continue }
                        end = min(end, top)
                    }
                    if end == previous { break }
                }
            }
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: 0, y: start, width: 720, height: end - start)
            let bytes: Data = try await withCheckedThrowingContinuation { continuation in
                web.createPDF(configuration: configuration) { continuation.resume(with: $0) }
            }
            try Task.checkCancellation()
            guard let provider = CGDataProvider(data: bytes as CFData), let pdf = CGPDFDocument(provider), let page = pdf.page(at: 1) else { throw Failure.rendering }
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor); context.fill(media)
            context.saveGState()
            let target = CGRect(x: 36, y: 792 - 36 - (end - start) * 0.75, width: 540, height: (end - start) * 0.75)
            context.concatenate(page.getDrawingTransform(.mediaBox, rect: target, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            context.restoreGState(); context.endPDFPage()
            start = end; count += 1
            progress(min(1, start / height))
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(Failure.rendering)) }
    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil; deadline?.cancel(); deadline = nil
        exportTask?.cancel(); exportTask = nil
        webView?.navigationDelegate = nil; webView?.stopLoading()
        window?.contentView = nil; window?.close(); window = nil; webView = nil
        continuation.resume(with: result)
    }
}
