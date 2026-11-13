import SwiftUI
import WebKit

enum MarkdownPreviewNavigation {
    @MainActor static func policy(for type: WKNavigationType, url: URL?, offline: Bool,
                                  open: (URL) -> Void = { NSWorkspace.shared.open($0) }) -> WKNavigationActionPolicy {
        if type == .other, url?.scheme == "about" { return .allow }
        if type == .linkActivated, !offline, let url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            open(url)
        }
        return .cancel
    }
}

@MainActor
final class MarkdownPreviewModel: NSObject, ObservableObject, WKNavigationDelegate {
    var sourceSelection: ((Int, String) -> Void)?
    @Published private(set) var html: String?
    private static let emptyHTML = "<!doctype html><html><head><meta charset=\"utf-8\"><style>\(MarkdownHTML.browserLinkStyle)</style></head><body></body></html>"
    var showsWebPreview: Bool { loaded || (html != nil && html != Self.emptyHTML) }
    @Published var message: String?
    @Published var sections: [SearchMarkdown.Heading] = []
    @Published var wordCount = 0
    private var htmlRevision = 0
    private var displayedRevision: Int?
    private var navigation: WKNavigation?
    private var replacement: UUID?
    private var loaded = false
    private var requestedLine: Int?
    private var requestedSection: Int?
    private var dark = false
    private var scale: CGFloat = 1
    private var wide = false
    private var serif = false
    private var appliedCSS: String?
    private var appliedOffline: Bool?
    private var renderGeneration = UUID()
    private var analysedSource: String?
    private var renderedSource: String?
    private var renderedURL: URL?
    private let remoteImages = MarkdownRemoteImages()
    private var networkObserver: NSObjectProtocol?
    override init() {
        super.init()
        networkObserver = NotificationCenter.default.addObserver(forName: NetworkAccessGate.changed, object: NetworkAccess.gate, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRemotePolicy() }
        }
    }
    deinit { if let networkObserver { NotificationCenter.default.removeObserver(networkObserver) } }
    private(set) lazy var web: WKWebView = {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(remoteImages, forURLScheme: MarkdownRemoteImages.scheme)
        configuration.userContentController.addUserScript(WKUserScript(source: MarkdownImagePresentation.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let bridge = MarkdownSourceBridge(); bridge.model = self
        configuration.userContentController.add(bridge, name: "sourceLocation")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.navigationScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isHidden = true
        web.navigationDelegate = self; web.setAccessibilityLabel("Markdown preview")
        return web
    }()
    func render(_ source: String, url: URL, includeHTML: Bool = true) async {
        let token = UUID(); renderGeneration = token
        let analyse = analysedSource != source
        let renderHTML = includeHTML && (renderedSource != source || renderedURL != url || html == nil || message != nil)
        guard analyse || renderHTML else { return }
        do { try await Task.sleep(for: .milliseconds(180)); try Task.checkCancellation() } catch { return }
        guard renderGeneration == token else { return }
        let emptyHTML = Self.emptyHTML
        let cachedSections = sections
        let worker = Task.detached(priority: .userInitiated) {
            let sections = analyse ? SearchMarkdown.headings(source) : cachedSections
            try Task.checkCancellation()
            let wordCount = analyse ? try Self.countWords(source) : nil
            let html: Result<String, Error>? = renderHTML ? Result {
                guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return emptyHTML }
                var renderer = MarkdownHTML(baseURL: url, preview: true)
                let anchors = Dictionary(uniqueKeysWithValues: sections.map { ($0.line, $0.number) })
                return try renderer.document(source, anchors: anchors)
            } : nil
            try Task.checkCancellation()
            return (html: html, sections: sections, wordCount: wordCount)
        }
        do {
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation(); guard renderGeneration == token else { return }
            if let count = result.wordCount {
                analysedSource = source
                if sections != result.sections { sections = result.sections }
                if wordCount != count { wordCount = count }
            }
            if let output = try result.html?.get() {
                renderedSource = source; renderedURL = url
                htmlRevision += 1
                html = output; message = nil
            }
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, renderGeneration == token else { return }
            // Incomplete fences/formulas are normal during composition. Keep the last good view.
            if case MarkdownHTML.Failure.markup = error { message = "Preview is waiting for complete Markdown. Your source is unchanged." }
            else { message = "Preview: \(error.localizedDescription) Your source is unchanged." }
        }
    }
    private nonisolated static func countWords(_ source: String) throws -> Int {
        var count = 0, inWord = false
        for (index, character) in source.enumerated() {
            if index.isMultiple(of: 4096) { try Task.checkCancellation() }
            let word = !character.isWhitespace
            if word && !inWord { count += 1 }
            inWord = word
        }
        return count
    }
    func display(dark: Bool, scale: CGFloat, wide: Bool, serif: Bool) {
        self.dark = dark; self.scale = scale; self.wide = wide; self.serif = serif
        let appearance: NSAppearance.Name = dark ? .darkAqua : .aqua
        if web.appearance?.name != appearance { web.appearance = NSAppearance(named: appearance) }
        let background = dark ? RemileStyle.slate : RemileStyle.paper
        if web.underPageBackgroundColor != background { web.underPageBackgroundColor = background }
        guard let html else { return }
        if web.pageZoom != scale { web.pageZoom = scale }
        if loaded {
            style()
            replaceBodyIfNeeded()
        } else if navigation == nil {
            displayedRevision = htmlRevision
            let themed = html.replacingOccurrences(of: "</head>", with: "<style id=\"reader-style\">\(themeCSS)</style></head>")
            navigation = web.loadHTMLString(themed, baseURL: nil)
        }
    }
    private func replaceBodyIfNeeded() {
        guard loaded, replacement == nil, displayedRevision != htmlRevision, let html else { return }
        let token = UUID()
        let revision = htmlRevision
        replacement = token
        web.callAsyncJavaScript(Self.replaceBody, arguments: ["html": html], in: nil, in: .page) { [weak self] result in
            guard let self, self.replacement == token else { return }
            self.replacement = nil
            self.displayedRevision = revision
            if self.htmlRevision != revision {
                self.replaceBodyIfNeeded()
            } else {
                if case .failure = result, self.message == nil {
                    self.message = "Preview update failed. Render again."
                }
                self.revealPendingLocation()
            }
        }
    }
    private static let replaceBody = """
        const fraction = scrollY / Math.max(1, document.documentElement.scrollHeight - innerHeight);
        const next = new DOMParser().parseFromString(html, 'text/html');
        if (next.body.childNodes.length <= 8192) {
            document.body.replaceChildren(...next.body.childNodes);
        } else {
            // Bound the JavaScript argument count for documents with many top-level blocks.
            const contents = next.createRange();
            contents.selectNodeContents(next.body);
            document.body.replaceChildren(contents.extractContents());
        }
        window.remileSetOffline?.(window.remileOffline);
        scrollTo(0, fraction * Math.max(0, document.documentElement.scrollHeight - innerHeight));
        """
    private static func json(_ value: String) -> String { String(data: try! JSONEncoder().encode(value), encoding: .utf8)! }
    private var themeCSS: String {
        """
        :root{color-scheme:\(dark ? "dark" : "light")}html,body{background:\(dark ? "#202c35" : "#f3efe7");color:\(dark ? "#f3eadb" : "#293944")}body{font:18px \(serif ? "Georgia,serif" : "-apple-system,BlinkMacSystemFont,sans-serif");line-height:1.65;max-width:\(wide ? "none" : "760px");margin:auto;padding:32px 36px 64px}h1{font-size:2em}h2{font-size:1.6em}h3{font-size:1.3em}code{font:0.9em ui-monospace,monospace}pre{background:\(dark ? "#2b3740" : "#eeeae2");border-radius:6px;padding:16px;overflow:auto}th{background:\(dark ? "#34424c" : "#eeeae2")}th,td{border-color:\(dark ? "#596b77" : "#c4bdb3")}math[display=block]{font-size:1.15em}img{max-height:none}.picture-light{display:\(dark ? "none" : "inline")}.picture-dark{display:\(dark ? "inline" : "none")}a{color:\(dark ? "#d6b777" : "#a13f3b")} .source-anchor{display:block;height:0;scroll-margin-top:24px}
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
        requestedLine = line
        requestedSection = nil
        revealPendingLocation()
    }
    private func scrollToLine(_ line: Int) {
        web.evaluateJavaScript("(()=>{const a=[...document.querySelectorAll('[data-source-line]')].filter(a=>Number(a.dataset.sourceLine)<=\(max(0,line))).pop();a?.scrollIntoView({block:'center',behavior:matchMedia('(prefers-reduced-motion:reduce)').matches?'instant':'smooth'})})()", completionHandler: nil)
    }
    private func updateRemotePolicy() {
        if NetworkAccess.offline { remoteImages.cancelAll() }
        guard loaded else { return }
        guard appliedOffline != NetworkAccess.offline else { return }
        appliedOffline = NetworkAccess.offline
        web.evaluateJavaScript("window.remileSetOffline?.(\(NetworkAccess.offline ? "true" : "false"))", completionHandler: nil)
    }
    func pauseRemoteImages() { remoteImages.cancelAll() }
    func retryRemoteImages() {
        guard loaded, !NetworkAccess.offline else { return }
        remoteImages.clearFailures()
        web.evaluateJavaScript("document.querySelectorAll('.remote-image:not([data-loaded]) img').forEach(i=>{const b=i.closest('.remote-image');delete b.dataset.failed;i.src=i.dataset.remoteSrc})", completionHandler: nil)
    }
    private func style() {
        guard loaded else { return }
        updateRemotePolicy()
        if web.pageZoom != scale { web.pageZoom = scale }
        let css = themeCSS
        guard appliedCSS != css else { return }
        appliedCSS = css
        let encoded = Self.json(css)
        web.evaluateJavaScript("(()=>{let s=document.getElementById('reader-style');if(!s){s=document.createElement('style');s.id='reader-style';document.head.append(s)}s.textContent=\(encoded)})()", completionHandler: nil)
    }
    func reveal(section: Int) {
        requestedSection = section
        requestedLine = nil
        revealPendingLocation()
    }
    private func revealPendingLocation() {
        guard loaded, replacement == nil, displayedRevision == htmlRevision else { return }
        if let line = requestedLine {
            requestedLine = nil
            scrollToLine(line)
        } else if let section = requestedSection {
            requestedSection = nil
            web.evaluateJavaScript("document.getElementById('section-\(section)')?.scrollIntoView({block:'start'})", completionHandler: nil)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation else { return }
        self.navigation = nil
        loaded = true; style(); ReaderScrolling.configure(webView)
        webView.isHidden = false
        replaceBodyIfNeeded()
        revealPendingLocation()
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(MarkdownPreviewNavigation.policy(for: action.navigationType, url: action.request.url, offline: NetworkAccess.offline))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        initialLoadFailed(navigation)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        initialLoadFailed(navigation)
    }
    private func initialLoadFailed(_ navigation: WKNavigation?) {
        guard navigation != nil, navigation === self.navigation else { return }
        self.navigation = nil
        message = "Preview update failed. Render again."
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.isHidden = true
        navigation = nil; replacement = nil; displayedRevision = nil; loaded = false
        appliedCSS = nil; appliedOffline = nil
        message = "Preview paused. Switch view to reload it."
    }
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
            if rendering.showsWebPreview {
                MarkdownCanvas(model: rendering, dark: colorScheme == .dark, scale: scale, wide: wide, serif: serif)
            } else {
                Color.clear.accessibilityHidden(true)
            }
            if let message = rendering.message { Text(message).font(.system(size: 13)).foregroundStyle(.secondary).padding(10) }
        }.background(RemileStyle.background).onAppear { rendering.retryRemoteImages() }.onDisappear { rendering.pauseRemoteImages() }
            .task(id: source) { if schedulesRender { await rendering.render(source, url: fileURL ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Untitled.md")) } }
    }
}

private struct MarkdownCanvas: NSViewRepresentable {
    @ObservedObject var model: MarkdownPreviewModel
    let dark: Bool; let scale: CGFloat; let wide: Bool; let serif: Bool
    func makeNSView(context: Context) -> WKWebView {
        model.display(dark: dark, scale: scale, wide: wide, serif: serif)
        model.web.removeFromSuperview(); return model.web
    }
    func updateNSView(_ view: WKWebView, context: Context) { model.display(dark: dark, scale: scale, wide: wide, serif: serif) }
}

private final class MarkdownSourceBridge: NSObject, WKScriptMessageHandler {
    weak var model: MarkdownPreviewModel?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let value = message.body as? [String: Any], let line = value["line"] as? Int, line >= 0 else { return }
        model?.sourceSelection?(line, value["text"] as? String ?? "")
    }
}
