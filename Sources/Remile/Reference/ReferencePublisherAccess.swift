import SwiftUI
import WebKit

struct ReferencePublisherSource {
    let article: URL
    private static let sessionKey = "reference.publisher.scienceDirect.webStore"

    init?(_ url: URL?) {
        guard let url, ReferencePaperLookup.publicURL(url),
              let pii = ReferencePaperLookup.scienceDirectPII(url),
              let article = URL(string: "https://www.sciencedirect.com/science/article/pii/" + pii) else { return nil }
        self.article = article
    }

    var savedSession: UUID? {
        UserDefaults.standard.string(forKey: Self.sessionKey).flatMap(UUID.init(uuidString:))
    }

    func rememberSession() -> UUID {
        if let savedSession { return savedSession }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: Self.sessionKey)
        return id
    }

    @MainActor func forgetSession() async throws {
        guard let id = savedSession else { return }
        try await WKWebsiteDataStore.remove(forIdentifier: id)
        UserDefaults.standard.removeObject(forKey: Self.sessionKey)
    }

    static func isPDFResponse(_ response: URLResponse, filename: String? = nil) -> Bool {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.url.map(ReferencePaperLookup.publicURL) == true else { return false }
        let mime = response.mimeType?.lowercased()
        return mime == "application/pdf" ||
            (mime == "application/octet-stream" && (filename ?? response.suggestedFilename)?.lowercased().hasSuffix(".pdf") == true)
    }
}

@MainActor
private final class ReferencePublisherSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    @Published private(set) var web: WKWebView?
    @Published private(set) var loading = false
    @Published private(set) var receiving = false
    @Published private(set) var issue: String?
    @Published private(set) var host = "www.sciencedirect.com"
    @Published private(set) var canGoBack = false
    private let source: ReferencePublisherSource
    private let record: ReferenceRecord
    private let receive: (ReferencePDFResolver.Found) -> Void
    private var lease: UUID?
    private var transfer: WKDownload?
    private var destination: URL?
    private var progress: NSKeyValueObservation?
    private var timeout: Task<Void, Never>?
    private var validation: Task<Void, Never>?

    init(source: ReferencePublisherSource, record: ReferenceRecord, receive: @escaping (ReferencePDFResolver.Found) -> Void) {
        self.source = source
        self.record = record
        self.receive = receive
    }

    func start(remember: Bool) {
        guard web == nil else { return }
        do {
            lease = try NetworkAccess.gate.watch { [weak self] in
                Task { @MainActor in self?.stop() }
            }
        } catch {
            issue = error.localizedDescription
            return
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = remember
            ? WKWebsiteDataStore(forIdentifier: source.rememberSession()) : .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        issue = nil
        host = source.article.host() ?? "www.sciencedirect.com"
        canGoBack = false
        loading = true
        web = view
        view.load(URLRequest(url: source.article))
    }

    func stop() {
        validation?.cancel()
        validation = nil
        endDownload()
        if let lease { NetworkAccess.gate.release(lease); self.lease = nil }
        web?.stopLoading()
        web?.navigationDelegate = nil
        web?.uiDelegate = nil
        web?.loadHTMLString("", baseURL: nil)
        web = nil
        loading = false
    }

    private func endDownload() {
        progress = nil
        timeout?.cancel()
        timeout = nil
        transfer?.delegate = nil
        transfer?.cancel(nil)
        transfer = nil
        if let destination { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        destination = nil
        receiving = false
    }

    private func failDownload(_ message: String) {
        endDownload()
        issue = message
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard web === webView, !NetworkAccess.offline, let url = action.request.url,
              ReferencePaperLookup.publicURL(url) || ["about:blank", "about:srcdoc"].contains(url.absoluteString) else { return .cancel }
        return action.shouldPerformDownload ? .download : .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard web === webView, !NetworkAccess.offline, let url = response.response.url else { return .cancel }
        if !response.isForMainFrame, ["about:blank", "about:srcdoc"].contains(url.absoluteString) { return .allow }
        guard ReferencePaperLookup.publicURL(url) else { return .cancel }
        if ReferencePublisherSource.isPDFResponse(response.response) {
            return response.isForMainFrame && !receiving ? .download : .cancel
        }
        return response.canShowMIMEType ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if web === webView, !NetworkAccess.offline, action.targetFrame == nil,
           action.request.url.map(ReferencePaperLookup.publicURL) == true {
            webView.load(action.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        issue = nil
        loading = true
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        host = webView.url?.host() ?? ""
        canGoBack = webView.canGoBack
        loading = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        if receiving || (error as? URLError)?.code == .cancelled { return }
        issue = "This page couldn’t open."
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        accept(download, from: webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        accept(download, from: webView)
    }

    private func accept(_ download: WKDownload, from view: WKWebView) {
        guard web === view, !receiving, !NetworkAccess.offline else { download.cancel(nil); return }
        issue = nil
        loading = false
        receiving = true
        transfer = download
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        guard download === transfer, !NetworkAccess.offline else { return nil }
        guard ReferencePublisherSource.isPDFResponse(response, filename: suggestedFilename) else {
            failDownload("The publisher did not return a PDF.")
            return nil
        }
        let limit = Int64(ReferencePaperLookup.pdfLimit)
        guard response.expectedContentLength <= limit else {
            failDownload("Choose a PDF smaller than 25 MB.")
            return nil
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remile-paper-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            failDownload("The PDF could not be saved.")
            return nil
        }
        let file = folder.appendingPathComponent("paper.pdf")
        destination = file
        let id = ObjectIdentifier(download)
        progress = download.progress.observe(\.completedUnitCount, options: [.new]) { [weak self] progress, _ in
            guard progress.completedUnitCount > limit else { return }
            Task { @MainActor in
                guard let self, self.transfer.map(ObjectIdentifier.init) == id else { return }
                self.failDownload("Choose a PDF smaller than 25 MB.")
            }
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            self?.failDownload("The download timed out. Try downloading the PDF again.")
        }
        return file
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest) async -> WKDownload.RedirectPolicy {
        download === transfer && !NetworkAccess.offline && request.url.map(ReferencePaperLookup.publicURL) == true ? .allow : .cancel
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard download === transfer, let file = destination, !NetworkAccess.offline else { return }
        progress = nil
        timeout?.cancel()
        timeout = nil
        transfer = nil
        let record = record
        let article = source.article
        validation = Task { [weak self] in
            let work = Task.detached { try ReferencePDFResolver.readLocal(file, for: record) }
            do {
                let data = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                guard let self, !NetworkAccess.offline else { return }
                self.stop()
                self.receive(.init(data: data, source: article, version: "Publisher PDF"))
            } catch {
                guard !Task.isCancelled else { return }
                self?.failDownload(error.localizedDescription)
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if download === transfer { failDownload("The download stopped. Try downloading the PDF again.") }
    }
}

struct ReferencePublisherAccess: View {
    let source: ReferencePublisherSource
    let close: () -> Void
    @ObservedObject private var network = NetworkAccessState.shared
    @Environment(\.openURL) private var openURL
    @StateObject private var session: ReferencePublisherSession
    @State private var clearing = false
    @State private var clearError: String?
    @State private var sessionChange: Task<Void, Never>?

    init(source: ReferencePublisherSource, record: ReferenceRecord, close: @escaping () -> Void,
         receive: @escaping (ReferencePDFResolver.Found) -> Void) {
        self.source = source
        self.close = close
        _session = StateObject(wrappedValue: ReferencePublisherSession(source: source, record: record, receive: receive))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let web = session.web {
                PublisherWebView(web: web).id(ObjectIdentifier(web))
            } else if clearing {
                ProgressView("Clearing saved sign-in…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(network.offline ? "Work offline is on." : "ScienceDirect is unavailable.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let issue = clearError ?? session.issue {
                Text(issue).font(RemileType.caption).foregroundStyle(RemileStyle.warning)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }
        .onAppear { session.start(remember: source.savedSession != nil) }
        .onDisappear {
            sessionChange?.cancel()
            session.stop()
        }
    }

    private var toolbar: some View {
        HStack(spacing: RemileControl.spacing) {
            Button(action: close) { SymbolIcon(systemName: "chevron.left") }
                .buttonStyle(RemileToolStyle()).keyboardShortcut(.cancelAction)
                .accessibilityLabel("Back to results").remileHelp("Back to results")
            Text(session.host).font(RemileType.callout).lineLimit(1).textSelection(.enabled)
            Spacer()
            if session.receiving || session.loading {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(session.receiving ? "Preparing PDF" : "Loading page")
            }
            Menu {
                if session.canGoBack {
                    Button("Previous web page") { session.web?.goBack() }
                }
                Button("Reload page") {
                    if let web = session.web { web.reload() }
                    else { session.start(remember: source.savedSession != nil) }
                }
                Button { openURL(source.article); close() } label: {
                    ExternalLinkLabel("Open in browser")
                }.accessibilityHint("Opens in your browser").disabled(network.offline)
                Divider()
                if source.savedSession != nil {
                    Button("Forget sign-in", action: forget)
                } else {
                    Button("Remember sign-in on this Mac") {
                        session.stop()
                        session.start(remember: true)
                    }
                }
            } label: { SymbolIcon(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(RemileStyle.ink)
                .frame(width: RemileControl.toolHit, height: RemileControl.toolHit)
                .accessibilityLabel("More actions").remileHelp("More actions")
                .disabled(clearing || network.offline || session.receiving)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    private func forget() {
        clearing = true
        clearError = nil
        session.stop()
        sessionChange = Task { @MainActor in
            defer { clearing = false }
            do {
                try await source.forgetSession()
            } catch {
                clearError = "Close any other ScienceDirect windows and try again."
            }
            if !Task.isCancelled && !NetworkAccess.offline {
                session.start(remember: source.savedSession != nil)
            }
        }
    }
}

private struct PublisherWebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
