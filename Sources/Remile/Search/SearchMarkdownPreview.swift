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
            let anchors = Dictionary(uniqueKeysWithValues: SearchMarkdown.sections(source).map { ($0.line, $0.number) })
            var renderer = MarkdownHTML(baseURL: url)
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
                Button { open(URL(fileURLWithPath: hit.path)) } label: { Label("Open", systemImage: "arrow.up.right.square") }
            }.padding(16)
            Divider()
            if let html = model.html { SearchMarkdownCanvas(html: html, section: hit.page, query: query, dark: colorScheme == .dark, citation: citation, zoom: zoom) }
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
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var html = "", section = 0, query = "", dark = false, loaded = false
        var generation = UUID()
        var citation: AssistantCitation?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.navigationType == .other && action.request.url?.scheme == "about" ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true; refresh(webView) }
        func refresh(_ web: WKWebView) {
            guard loaded else { return }
            generation = UUID(); let token = generation, query = query, section = section, citation = citation
            let scopeScript = """
            const anchor=document.getElementById('section-\(section)');
            const anchors=[...document.querySelectorAll('[id^="section-"]')];
            const next=anchor ? anchors[anchors.indexOf(anchor)+1] : null;
            const included=n=>\(citation != nil ? "true" : "false") ? (!anchor ? false : (anchor.contains(n) || !!(anchor.compareDocumentPosition(n)&Node.DOCUMENT_POSITION_FOLLOWING)) && (!next || !!(next.compareDocumentPosition(n)&Node.DOCUMENT_POSITION_PRECEDING))) : true;
            """
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
            Task { @MainActor [weak self, weak web] in
                guard let self, let web else { return }
                do {
                    let text = try await web.evaluateJavaScript(textScript) as? String ?? ""
                    guard token == self.generation else { return }
                    let ranges = citation?.ranges(in: text) ?? SearchText.matches(text, query: query).map(\.range)
                    let matches = ranges.map { [$0.location, $0.length] }
                    let json = String(data: try JSONSerialization.data(withJSONObject: matches), encoding: .utf8)!
                    let paper = self.dark ? "#222C35" : "#F0E7D7", ink = self.dark ? "#F0E7D7" : "#222C35"
                    let script = """
                    (() => {
                      document.documentElement.style.background='\(paper)';
                      document.body.style.cssText='padding:32px 32px 80vh;max-width:850px;margin:auto;background:\(paper);color:\(ink);font-size:15px;';
                      let style=document.getElementById('search-theme');
                      if(!style){style=document.createElement('style');style.id='search-theme';document.head.append(style);}
                      style.textContent='th{background:\(self.dark ? "#34414C" : "#E1D6C5");color:\(ink)}pre{background:\(self.dark ? "#1B242C" : "#E8DECF")}th,td{border-color:\(self.dark ? "#56616A" : "#B8ADA0")}';
                      \(scopeScript)
                      const walk=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT), nodes=[];let node,offset=0;
                      while(node=walk.nextNode()) if(!['STYLE','SCRIPT'].includes(node.parentElement?.tagName) && included(node)){nodes.push({node,start:offset,end:offset+node.length});offset+=node.length+1;}
                      for(const [start,length] of \(json).reverse()) for(const item of [...nodes].reverse()){
                        const a=Math.max(start,item.start)-item.start,b=Math.min(start+length,item.end)-item.start;
                        if(b>a){const range=document.createRange();range.setStart(item.node,a);range.setEnd(item.node,b);const mark=document.createElement('mark');mark.style.cssText='background:#F0E442;color:#222C35;border-radius:2px';range.surroundContents(mark);}
                      }
                      const firstMark=\(citation != nil ? "true" : "false") ? document.querySelector('mark') : null;
                      (firstMark ?? anchor)?.scrollIntoView({block:'start'});
                      return document.querySelectorAll('mark').length;
                    })()
                    """
                    _ = try await web.evaluateJavaScript(script)
                } catch { /* The document may have changed during navigation. */ }
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config); web.navigationDelegate = context.coordinator
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        zoom?.attach(web)
        let state = context.coordinator, newDocument = state.html != html
        let changed = state.section != section || state.query != query || state.dark != dark || state.citation?.id != citation?.id
        state.section = section; state.query = query; state.dark = dark; state.citation = citation
        if newDocument { state.html = html; state.loaded = false; state.generation = UUID(); web.loadHTMLString(html, baseURL: nil) }
        else if changed { state.refresh(web) }
    }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) { coordinator.generation = UUID(); web.stopLoading(); web.navigationDelegate = nil }
}
