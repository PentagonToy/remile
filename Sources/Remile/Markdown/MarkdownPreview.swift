import SwiftUI
import WebKit

@MainActor
final class MarkdownPreviewModel: NSObject, ObservableObject, WKNavigationDelegate {
    var sourceSelection: ((Int, String) -> Void)?
    @Published var html: String?
    @Published var message: String?
    @Published var sections: [SearchMarkdown.Section] = []
    @Published var wordCount = 0
    private var loadedHTML = ""
    private var loaded = false
    private var fraction = 0.0
    private var requestedLine: Int?
    private var requestedSection: Int?
    private var dark = false
    private var scale: CGFloat = 1
    private var wide = false
    private var serif = false
    private var generation = UUID()
    private var renderGeneration = UUID()
    private(set) lazy var web: WKWebView = {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let bridge = MarkdownSourceBridge(); bridge.model = self
        configuration.userContentController.add(bridge, name: "sourceLocation")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.navigationScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self; web.setAccessibilityLabel("Markdown preview")
        return web
    }()
    func render(_ source: String, url: URL) async {
        let token = UUID(); renderGeneration = token
        do { try await Task.sleep(for: .milliseconds(180)); try Task.checkCancellation() } catch { return }
        let worker = Task.detached(priority: .userInitiated) { () throws -> (String, [SearchMarkdown.Section], Int) in
            let sections = SearchMarkdown.sections(source)
            var renderer = MarkdownHTML(baseURL: url)
            let anchors = Dictionary(uniqueKeysWithValues: sections.map { ($0.line, $0.number) })
            let html = source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "<!doctype html><html><head><meta charset=\"utf-8\"></head><body></body></html>" : try renderer.document(source, anchors: anchors)
            try Task.checkCancellation()
            return (html, sections, source.split(whereSeparator: \.isWhitespace).count)
        }
        do {
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation(); guard renderGeneration == token else { return }; html = result.0; sections = result.1; wordCount = result.2; message = nil
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, renderGeneration == token else { return }
            // Incomplete fences/formulas are normal during composition. Keep the last good view.
            if case MarkdownHTML.Failure.markup = error { message = "Preview is waiting for complete Markdown. Your source is unchanged." }
            else { message = "Preview: \(error.localizedDescription) Your source is unchanged." }
        }
    }
    func display(dark: Bool, scale: CGFloat, wide: Bool, serif: Bool) {
        self.dark = dark; self.scale = scale; self.wide = wide; self.serif = serif
        guard let html else { return }
        web.pageZoom = scale
        if loadedHTML != html {
            if loaded {
                loadedHTML = html
                let encoded = Self.json(html)
                web.evaluateJavaScript("(()=>{const y=scrollY/Math.max(1,document.documentElement.scrollHeight-innerHeight);const next=new DOMParser().parseFromString(\(encoded),'text/html');document.body.replaceChildren(...next.body.childNodes);scrollTo(0,y*Math.max(0,document.documentElement.scrollHeight-innerHeight))})()") { [weak self] _, error in
                    if error != nil { self?.loadedHTML = ""; self?.message = "Preview update failed. Render again." }
                }
                style()
            } else if !web.isLoading {
                loadedHTML = html
                let themed = html.replacingOccurrences(of: "</head>", with: "<style id=\"reader-style\">\(themeCSS)</style></head>")
                web.loadHTMLString(themed, baseURL: nil)
            }
        } else { style() }
    }
    private static func json(_ value: String) -> String { String(data: try! JSONEncoder().encode(value), encoding: .utf8)! }
    private var themeCSS: String {
        """
        html,body{background:\(dark ? "#232120" : "#fbf8f2");color:\(dark ? "#eee9df" : "#252321")}body{font:18px \(serif ? "Georgia,serif" : "-apple-system,BlinkMacSystemFont,sans-serif");line-height:1.65;max-width:\(wide ? "none" : "760px");margin:auto;padding:32px 36px 64px}h1{font-size:2em}h2{font-size:1.6em}h3{font-size:1.3em}code{font:0.9em ui-monospace,monospace}pre{background:\(dark ? "#302d2b" : "#eeeae2");border-radius:6px;padding:16px;overflow:auto}th{background:\(dark ? "#37332e" : "#eeeae2")}th,td{border-color:\(dark ? "#625c55" : "#c4bdb3")}math[display=block]{font-size:1.15em}img{max-height:none}a{color:\(dark ? "#edaaa2" : "#a13f3b")} .source-anchor{display:block;height:0;scroll-margin-top:24px}
        """
    }
    private static let navigationScript = """
    window.remileLocation = function(node) {
      node = node || window.getSelection()?.anchorNode || document.elementFromPoint(innerWidth/2, Math.min(120,innerHeight/2));
      let line = 0;
      for (const anchor of document.querySelectorAll('[data-source-line]')) {
        if (node && (anchor === node || (anchor.compareDocumentPosition(node) & Node.DOCUMENT_POSITION_FOLLOWING))) line = Number(anchor.dataset.sourceLine);
      }
      return {line:line, text:window.getSelection()?.toString().slice(0,200) || ''};
    };
    document.addEventListener('dblclick', function(event) { window.webkit.messageHandlers.sourceLocation.postMessage(window.remileLocation(event.target)); });
    """
    func revealSource() {
        web.evaluateJavaScript("window.remileLocation?.()") { [weak self] value, _ in
            guard let info = value as? [String: Any], let line = info["line"] as? Int else { return }
            self?.sourceSelection?(line, info["text"] as? String ?? "")
        }
    }
    func reveal(line: Int) {
        guard loaded else { requestedLine = line; return }
        web.evaluateJavaScript("(()=>{const a=[...document.querySelectorAll('[data-source-line]')].filter(a=>Number(a.dataset.sourceLine)<=\(max(0,line))).pop();a?.scrollIntoView({block:'center',behavior:matchMedia('(prefers-reduced-motion:reduce)').matches?'instant':'smooth'})})()", completionHandler: nil)
    }
    private func style() {
        guard loaded else { return }
        let encoded = Self.json(themeCSS)
        web.pageZoom = scale
        web.evaluateJavaScript("(()=>{let s=document.getElementById('reader-style');if(!s){s=document.createElement('style');s.id='reader-style';document.head.append(s)}s.textContent=\(encoded)})()", completionHandler: nil)
    }
    func reveal(section: Int) {
        requestedSection = section; scrollToSection()
    }
    private func scrollToSection() {
        guard loaded, let section = requestedSection else { return }
        web.evaluateJavaScript("document.getElementById('section-\(section)')?.scrollIntoView({block:'start'})", completionHandler: nil)
        requestedSection = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true; style(); ReaderScrolling.configure(webView)
        if loadedHTML != html { display(dark: dark, scale: scale, wide: wide, serif: serif) }
        if let line = requestedLine { requestedLine = nil; reveal(line: line) }
        else if requestedSection != nil { scrollToSection() }
        else { web.evaluateJavaScript("window.scrollTo(0,\(min(1,max(0,fraction)))*Math.max(0,document.documentElement.scrollHeight-innerHeight))", completionHandler: nil) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .other, action.request.url?.scheme == "about" { decisionHandler(.allow); return }
        if action.navigationType == .linkActivated, let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { loadedHTML = ""; message = "Preview paused. Switch view to reload it." }
}

struct MarkdownPreview: View {
    let source: String
    var scale: CGFloat = 1
    var wide = false
    var fileURL: URL? = nil
    var serif = false
    private let schedulesRender: Bool
    @StateObject private var rendering: MarkdownPreviewModel
    @Environment(\.colorScheme) private var colorScheme
    init(source: String, scale: CGFloat = 1, wide: Bool = false, fileURL: URL? = nil, serif: Bool = false, model: MarkdownPreviewModel? = nil) {
        schedulesRender = model == nil
        self.source = source; self.scale = scale; self.wide = wide; self.fileURL = fileURL; self.serif = serif
        _rendering = StateObject(wrappedValue: model ?? MarkdownPreviewModel())
    }
    var body: some View {
        VStack(spacing: 0) {
            MarkdownCanvas(model: rendering, dark: colorScheme == .dark, scale: scale, wide: wide, serif: serif)
            if let message = rendering.message { Text(message).font(.system(size: 13)).foregroundStyle(.secondary).padding(10) }
        }.task(id: source) { if schedulesRender { await rendering.render(source, url: fileURL ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Untitled.md")) } }
    }
}

private struct MarkdownCanvas: NSViewRepresentable {
    @ObservedObject var model: MarkdownPreviewModel
    let dark: Bool; let scale: CGFloat; let wide: Bool; let serif: Bool
    func makeNSView(context: Context) -> WKWebView { model.web.removeFromSuperview(); return model.web }
    func updateNSView(_ view: WKWebView, context: Context) { model.display(dark: dark, scale: scale, wide: wide, serif: serif) }
}

private final class MarkdownSourceBridge: NSObject, WKScriptMessageHandler {
    weak var model: MarkdownPreviewModel?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let value = message.body as? [String: Any], let line = value["line"] as? Int, line >= 0 else { return }
        model?.sourceSelection?(line, value["text"] as? String ?? "")
    }
}
