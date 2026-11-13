import SwiftUI
import WebKit

@MainActor
final class SearchMarkdownModel: ObservableObject {
    @Published var html: String?
    @Published var error: String?
    func load(path: String) async {
        html = nil; error = nil
        let worker = Task.detached(priority: .userInitiated) { () throws -> String in
            let url = URL(fileURLWithPath: path), source = try SearchMarkdown.read(url)
            try Task.checkCancellation()
            let anchors = Dictionary(uniqueKeysWithValues: SearchMarkdown.headings(source).map { ($0.line, $0.number) })
            var renderer = MarkdownHTML(baseURL: url, preview: true)
            return try renderer.document(source, anchors: anchors)
        }
        do {
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation(); html = result
        } catch { if !Task.isCancelled { self.error = "Preview unavailable. Open the document." } }
    }
}

struct SearchMarkdownPreview: View {
    let hit: LibraryHit
    let query: String
    let revision: UUID
    let open: (URL) -> Void
    var citation: AssistantCitation? = nil
    @StateObject private var model = SearchMarkdownModel()
    @StateObject private var zoom = ReaderZoom(text: true)
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(hit.name).font(RemileType.heading).lineLimit(1)
                    Text(hit.location).font(RemileType.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ReaderZoomControls(zoom: zoom, text: true)
                Button("Open Markdown") { open(URL(fileURLWithPath: hit.path)) }.fixedSize()
            }.padding(16)
            Divider()
            if let html = model.html { SearchMarkdownCanvas(html: html, section: hit.page, query: query, dark: colorScheme == .dark, citation: citation, zoom: zoom, wide: zoom.wide) }
            else if let error = model.error { ContentUnavailableView(error, systemImage: "exclamationmark.triangle") }
            else { ProgressView("Loading Markdown…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.task(id: hit.path + revision.uuidString) { await model.load(path: hit.path) }
    }
}

struct SearchMarkdownCanvas: NSViewRepresentable {
    let html: String
    let section: Int
    let query: String
    let dark: Bool
    var citation: AssistantCitation? = nil
    var zoom: ReaderZoom? = nil
    var wide = false
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var html = "", section = 0, query = "", dark = false, loaded = false
        var wide = false
        private var readingWidth: String { wide ? "none" : "850px" }
        private var generation = UUID()
        var navigation: WKNavigation?
        private var highlightTask: Task<Void, Never>?
        var citation: AssistantCitation?
        let remoteImages = MarkdownRemoteImages()
        weak var web: WKWebView?
        private var networkObserver: NSObjectProtocol?
        override init() {
            super.init()
            networkObserver = NotificationCenter.default.addObserver(forName: NetworkAccessGate.changed, object: NetworkAccess.gate, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyRemotePolicy() }
            }
        }
        deinit { if let networkObserver { NotificationCenter.default.removeObserver(networkObserver) } }
        func applyRemotePolicy() {
            if NetworkAccess.offline { remoteImages.cancelAll() }
            guard loaded, let web else { return }
            web.evaluateJavaScript("window.remileSetOffline?.(\(NetworkAccess.offline ? "true" : "false"))", completionHandler: nil)
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(MarkdownPreviewNavigation.policy(for: action.navigationType, url: action.request.url, offline: NetworkAccess.offline))
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let navigation, navigation === self.navigation else { return }
            self.navigation = nil
            loaded = true
            applyRemotePolicy()
            applyAppearance(webView)
            refreshHighlights(webView)
        }
        func applyAppearance(_ web: WKWebView) {
            guard loaded else { return }
            let paper = dark ? "#222C35" : "#F0E7D7", ink = dark ? "#F0E7D7" : "#222C35"
            web.evaluateJavaScript("""
            (() => {
              document.documentElement.style.background='\(paper)';
              document.body.style.cssText='padding:32px 32px 80vh;max-width:\(readingWidth);margin:auto;background:\(paper);color:\(ink);font-size:15px;';
              let style=document.getElementById('search-theme');
              if(!style){style=document.createElement('style');style.id='search-theme';document.head.append(style);}
              style.textContent='th{background:\(dark ? "#34414C" : "#E1D6C5");color:\(ink)}pre{background:\(dark ? "#1B242C" : "#E8DECF")}th,td{border-color:\(dark ? "#56616A" : "#B8ADA0")}';
            })()
            """, completionHandler: nil)
        }
        func applyReadingWidth(_ web: WKWebView) {
            guard loaded else { return }
            web.evaluateJavaScript("document.body.style.maxWidth='\(readingWidth)'", completionHandler: nil)
        }
        func reveal(_ web: WKWebView) {
            guard loaded else { return }
            web.evaluateJavaScript(revealScript, completionHandler: nil)
        }
        private var revealScript: String {
            let anchor = "document.getElementById('section-\(section)')"
            let target = citation == nil ? anchor : "(document.querySelector('mark') ?? \(anchor))"
            return "\(target)?.scrollIntoView({block:'start'})"
        }
        func refreshHighlights(_ web: WKWebView) {
            guard loaded else { return }
            cancelHighlighting()
            let token = generation, query = query, section = section, citation = citation
            let scopeScript: String
            if citation == nil { scopeScript = "const included = () => true;" }
            else {
                let next = section == Int.max ? "null" : "document.getElementById('section-\(section + 1)')"
                scopeScript = """
                const anchor=document.getElementById('section-\(section)');
                const next=\(next);
                const included=n=>anchor && (anchor.contains(n) || !!(anchor.compareDocumentPosition(n)&Node.DOCUMENT_POSITION_FOLLOWING)) && (!next || !!(next.compareDocumentPosition(n)&Node.DOCUMENT_POSITION_PRECEDING));
                """
            }
            let textScript = """
            (() => {
              for (const mark of [...document.querySelectorAll('mark')]) mark.replaceWith(...mark.childNodes);
              document.body.normalize();
              \(scopeScript)
              const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT); const nodes=[]; let node;
              while (node=walk.nextNode()) if(!['STYLE','SCRIPT'].includes(node.parentElement?.tagName) && included(node)) nodes.push(node);
              return nodes.map(n=>n.textContent).join(' ');
            })()
            """
            highlightTask = Task { @MainActor [weak self, weak web] in
                guard let web else { return }
                do {
                    let text = try await web.evaluateJavaScript(textScript) as? String ?? ""
                    guard !Task.isCancelled, self?.generation == token else { return }
                    let worker = Task.detached(priority: .userInitiated) {
                        let ranges = citation?.ranges(in: text) ?? SearchText.matches(text, query: query).map(\.range)
                        return ranges.map { [$0.location, $0.length] }
                    }
                    let matches = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                    guard !Task.isCancelled, let self, token == self.generation else { return }
                    let json = String(data: try JSONSerialization.data(withJSONObject: matches), encoding: .utf8)!
                    let script = """
                    (() => {
                      \(scopeScript)
                      const walk=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT), nodes=[];let node,offset=0;
                      while(node=walk.nextNode()) if(!['STYLE','SCRIPT'].includes(node.parentElement?.tagName) && included(node)){nodes.push({node,start:offset,end:offset+node.length});offset+=node.length+1;}
                      for (const [start,length] of \(json).reverse()) {
                        let left=0,right=nodes.length;
                        while(left<right){const middle=(left+right)>>>1;if(nodes[middle].start<start+length)left=middle+1;else right=middle;}
                        for(let index=left-1;index>=0&&nodes[index].end>start;index--){
                          const item=nodes[index],a=Math.max(start,item.start)-item.start,b=Math.min(start+length,item.end)-item.start;
                          if(b>a){const range=document.createRange();range.setStart(item.node,a);range.setEnd(item.node,b);const mark=document.createElement('mark');mark.style.cssText='background:#F0E442;color:#222C35;border-radius:2px';range.surroundContents(mark);}
                        }
                      }
                      \(self.revealScript);
                    })()
                    """
                    _ = try await web.evaluateJavaScript(script)
                } catch { /* The document may have changed during navigation. */ }
            }
        }
        func cancelHighlighting() {
            highlightTask?.cancel()
            highlightTask = nil
            generation = UUID()
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(context.coordinator.remoteImages, forURLScheme: MarkdownRemoteImages.scheme)
        config.userContentController.addUserScript(WKUserScript(source: MarkdownImagePresentation.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config); web.navigationDelegate = context.coordinator; context.coordinator.web = web
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        zoom?.attach(web)
        let state = context.coordinator, newDocument = state.html != html
        let sectionChanged = state.section != section
        let highlightsChanged = state.query != query || state.citation?.id != citation?.id || (sectionChanged && citation != nil)
        let appearanceChanged = state.dark != dark
        let widthChanged = state.wide != wide
        state.section = section; state.query = query; state.dark = dark; state.citation = citation
        state.wide = wide
        if newDocument {
            state.cancelHighlighting()
            state.html = html
            state.loaded = false
            state.navigation = web.loadHTMLString(html, baseURL: nil)
        } else {
            if appearanceChanged { state.applyAppearance(web) }
            else if widthChanged { state.applyReadingWidth(web) }
            if highlightsChanged { state.refreshHighlights(web) }
            else if sectionChanged { state.reveal(web) }
        }
    }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) { coordinator.cancelHighlighting(); coordinator.remoteImages.cancelAll(); web.stopLoading(); web.navigationDelegate = nil }
}
