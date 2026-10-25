import SwiftUI
import WebKit

enum ReferencePublisherPolicy {
    static func source(_ record: ReferenceRecord) -> URL? {
        let doi = ReferenceDuplicates.normaliseDOI(record.fields["doi"] ?? "")
        if doi.hasPrefix("10.") {
            var url = URLComponents(string: "https://doi.org")!; url.path = "/" + doi
            return url.url
        }
        return record.fields["url"].flatMap(URL.init(string:)).flatMap { ReferencePaperLookup.publicURL($0) ? $0 : nil }
    }
    static func downloadable(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.url.map(ReferencePaperLookup.publicURL) == true,
              response.expectedContentLength <= ReferencePaperLookup.pdfLimit else { return false }
        let mime = response.mimeType?.lowercased() ?? ""
        return mime == "application/pdf" || (mime == "application/octet-stream" && response.suggestedFilename?.lowercased().hasSuffix(".pdf") == true)
    }
    static func accepted(_ data: Data, source: URL, record: ReferenceRecord) throws -> ReferencePDFResolver.Found {
        guard ReferencePaperLookup.publicURL(source), try ReferencePDFResolver.validate(data, for: record) else {
            throw ReferenceFailure("This PDF could not be matched to the selected reference.")
        }
        return .init(data: data, source: source, version: "Publisher download")
    }
}

/// An optional, window-scoped publisher session. Credentials and cookies stay in WebKit.
@MainActor final class ReferencePublisherSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, NSWindowDelegate {
    let web: WKWebView
    let record: ReferenceRecord
    private let identity: ReferencePublisherIdentity
    private var opening: Task<Void, Never>?
    @Published private(set) var rememberSignIn: Bool
    @Published private(set) var host = ""
    @Published private(set) var loading = false
    @Published private(set) var receiving = false
    @Published private(set) var canGoBack = false
    @Published private(set) var issue: String?
    @Published private(set) var found: ReferencePDFResolver.Found?
    private var lease: UUID?
    private var transfer: WKDownload?
    private var directory: URL?
    private var file: URL?
    private var source: URL?
    private var monitor: Task<Void, Never>?
    private var validation: Task<Void, Never>?
    private var popups: [NSWindow] = []
    private var active = false

    init(record: ReferenceRecord, rememberSignIn: Bool = UserDefaults.standard.bool(forKey: ReferencePublisherIdentity.preference)) {
        self.record = record
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let browser = WKWebView(frame: .zero, configuration: config); web = browser
        self.rememberSignIn = rememberSignIn
        identity = ReferencePublisherIdentity(store: browser.configuration.websiteDataStore.httpCookieStore, enabled: rememberSignIn)
        super.init(); configure(web)
        identity.failure = { [weak self] in self?.issue = $0 }
    }
    private func configure(_ view: WKWebView) { view.navigationDelegate = self; view.uiDelegate = self }
    func start() {
        guard !active else { return }
        do {
            try NetworkAccess.requireOnline()
            guard let url = ReferencePublisherPolicy.source(record) else { throw ReferenceFailure("Add a DOI or publisher URL first.") }
            lease = try NetworkAccess.gate.watch { [weak self] in Task { @MainActor in
                self?.stop(); self?.issue = NetworkAccessGate.Offline().localizedDescription
            } }
            active = true; issue = nil; loading = true; configure(web)
            opening = Task { [weak self] in
                guard let self else { return }
                await self.identity.restore()
                guard !Task.isCancelled, self.active, !NetworkAccess.offline else { return }
                self.web.load(URLRequest(url: url))
            }
        } catch { issue = error.localizedDescription }
    }
    func stop() {
        active = false; loading = false
        opening?.cancel(); opening = nil; identity.stop()
        if let lease { NetworkAccess.gate.release(lease); self.lease = nil }
        validation?.cancel(); validation = nil; resetDownload()
        web.stopLoading(); web.navigationDelegate = nil; web.uiDelegate = nil; web.loadHTMLString("", baseURL: nil)
        for window in popups {
            if let child = window.contentView as? WKWebView { child.stopLoading(); child.navigationDelegate = nil; child.uiDelegate = nil; child.loadHTMLString("", baseURL: nil) }
            window.close()
        }
        popups = []
    }
    private func resetDownload() {
        monitor?.cancel(); monitor = nil; transfer?.cancel { _ in }; transfer = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil; file = nil; source = nil; receiving = false
    }
    private func fail(_ message: String) { resetDownload(); issue = message }
    func back() { web.goBack() }
    func reload() { if active { web.reload() } else { start() } }
    func remember(_ enabled: Bool) { rememberSignIn = enabled; identity.remember(enabled) }
    func openInBrowser() {
        guard !NetworkAccess.offline, let url = ReferencePublisherPolicy.source(record) else { return }
        NSWorkspace.shared.open(url)
        issue = "Browser sign-in stays in your browser. Download the PDF there, then use Add local PDF."
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard active, !NetworkAccess.offline, let url = action.request.url,
              ReferencePaperLookup.publicURL(url) || url.absoluteString == "about:blank" else {
            decisionHandler(.cancel); return
        }
        decisionHandler(action.shouldPerformDownload ? .download : .allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if active, !NetworkAccess.offline, !response.isForMainFrame, ["about:blank", "about:srcdoc"].contains(response.response.url?.absoluteString ?? "") { decisionHandler(.allow); return }
        guard active, !NetworkAccess.offline, response.response.url.map(ReferencePaperLookup.publicURL) == true else { decisionHandler(.cancel); return }
        if ReferencePublisherPolicy.downloadable(response.response) {
            guard !receiving else { decisionHandler(.cancel); return }
            decisionHandler(.download)
        } else if response.canShowMIMEType && response.response.mimeType?.lowercased() != "application/pdf" { decisionHandler(.allow) }
        else { issue = "Choose a PDF smaller than 25 MB."; decisionHandler(.cancel) }
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { accept(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { accept(download) }
    private func accept(_ download: WKDownload) {
        guard active, !receiving, !NetworkAccess.offline else { download.cancel { _ in }; return }
        receiving = true; issue = nil; transfer = download; download.delegate = self
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard active, download === transfer, ReferencePublisherPolicy.downloadable(response) else { completionHandler(nil); fail("The publisher did not return a PDF."); return }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remile-publisher-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            directory = folder; file = folder.appendingPathComponent("paper.pdf"); source = response.url
            completionHandler(file)
            let deadline = Date().addingTimeInterval(120)
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    guard let self, self.active, let file = self.file else { return }
                    if ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > ReferencePaperLookup.pdfLimit {
                        self.fail("Choose a PDF smaller than 25 MB."); return
                    }
                    if Date() >= deadline { self.fail("The download timed out. Try downloading the PDF again."); return }
                }
            }
        } catch { completionHandler(nil); fail("The PDF could not be downloaded.") }
    }
    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        decisionHandler(active && !NetworkAccess.offline && request.url.map(ReferencePaperLookup.publicURL) == true ? .allow : .cancel)
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard active, download === transfer, let file, let source else { return }
        monitor?.cancel(); monitor = nil; transfer = nil
        let record = record
        validation = Task { [weak self] in
            do {
                let found = try await Task.detached { () throws -> ReferencePDFResolver.Found in
                    guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= ReferencePaperLookup.pdfLimit else { throw ReferenceFailure("Choose a PDF smaller than 25 MB.") }
                    let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                    let data = try handle.read(upToCount: ReferencePaperLookup.pdfLimit + 1) ?? Data()
                    return try ReferencePublisherPolicy.accepted(data, source: source, record: record)
                }.value
                try Task.checkCancellation()
                guard let self, self.active else { return }
                self.found = found
                self.stop()
            } catch {
                guard !Task.isCancelled, let self, self.active else { return }
                self.fail(error.localizedDescription)
            }
        }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard active, download === transfer else { return }; fail("The download stopped. Try downloading the PDF again.")
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true; issue = nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false; host = webView.url?.host ?? ""; canGoBack = web.canGoBack
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    private func navigationFailed(_ error: Error) {
        loading = false
        if active && (error as NSError).code != NSURLErrorCancelled { issue = "This page could not be opened. You can still add a local PDF." }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard active, !NetworkAccess.offline, popups.filter(\.isVisible).count < 3,
              navigationAction.request.url.map({ ReferencePaperLookup.publicURL($0) || $0.absoluteString == "about:blank" }) == true else { return nil }
        let child = WKWebView(frame: .zero, configuration: configuration); configure(child)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Publisher sign-in"; window.isReleasedWhenClosed = false; window.contentView = child; window.delegate = self
        window.center(); window.makeKeyAndOrderFront(nil); popups.append(window)
        return child
    }
    func webViewDidClose(_ webView: WKWebView) {
        guard webView !== web else { return }
        webView.stopLoading(); webView.navigationDelegate = nil; webView.uiDelegate = nil
        popups.first { $0.contentView === webView }?.close()
        popups.removeAll { $0.contentView === webView }
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let child = window.contentView as? WKWebView else { return }
        child.stopLoading(); child.navigationDelegate = nil; child.uiDelegate = nil; child.loadHTMLString("", baseURL: nil)
        popups.removeAll { $0 === window }
    }
}

struct ReferencePublisherAccess: View {
    @StateObject private var session: ReferencePublisherSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var network = NetworkAccessState.shared
    let received: (ReferencePDFResolver.Found) -> Void
    init(record: ReferenceRecord, received: @escaping (ReferencePDFResolver.Found) -> Void) {
        _session = StateObject(wrappedValue: ReferencePublisherSession(record: record)); self.received = received
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Publisher access").font(RemileType.heading)
                    Text(session.record.displayTitle).font(RemileType.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 10) {
                Button { session.back() } label: { Image(systemName: "chevron.left") }.disabled(!session.canGoBack || session.receiving).accessibilityLabel("Back")
                Button { session.reload() } label: { Image(systemName: "arrow.clockwise") }.disabled(session.receiving || network.offline).accessibilityLabel("Reload")
                Image(systemName: "lock").foregroundStyle(.secondary)
                Text(session.host.isEmpty ? "Publisher website" : session.host).font(RemileType.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Open in browser") { session.openInBrowser() }.disabled(network.offline).remileHelp("Use your browser if the publisher’s verification does not finish here.")
                if session.loading || session.receiving { ProgressView().controlSize(.small) }
            }
            PublisherWebView(web: session.web).clipShape(RoundedRectangle(cornerRadius: 6))
            if let issue = session.issue { Text(issue).font(RemileType.caption).foregroundStyle(RemileStyle.warning).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text(session.receiving ? "Checking the PDF…" : "Sign in on the website, then download the PDF.").font(RemileType.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Remember sign-in", isOn: Binding(get: { session.rememberSignIn }, set: session.remember)).toggleStyle(.switch).controlSize(.small)
                    .remileHelp("Keep this window’s session cookies in this Mac’s Keychain. Turn off to remove the saved copy. Passwords are not stored by remile.")
            }
        }.padding(20).frame(width: 900, height: 700).background(RemileStyle.background).tint(RemileStyle.accent)
            .onAppear { session.start() }.onDisappear { session.stop() }
            .onChange(of: session.found?.source) { _ in if let found = session.found { received(found); dismiss() } }
    }
}
private struct PublisherWebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ view: WKWebView, context: Context) { }
    static func dismantleNSView(_ view: WKWebView, coordinator: ()) { view.stopLoading() }
}
