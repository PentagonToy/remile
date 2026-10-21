import SwiftUI
import WebKit

/// A short-lived authentication surface, never the document editor.
@MainActor final class OverleafSignInSession: NSObject, ObservableObject, WKNavigationDelegate {
    let web: WKWebView
    private var networkLease: UUID?
    @Published var signedIn = false
    init(profile: UUID) {
        let config = WKWebViewConfiguration(); config.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile)
        web = WKWebView(frame: .zero, configuration: config)
        super.init(); web.navigationDelegate = self
        networkLease = try? NetworkAccess.gate.watch { [weak self] in Task { @MainActor in self?.web.stopLoading(); self?.web.navigationDelegate = nil; self?.web.loadHTMLString("<p>Offline mode is on.</p>", baseURL: nil) } }
        if !NetworkAccess.offline { web.load(URLRequest(url: URL(string: "https://www.overleaf.com/login")!)) }
        else { web.navigationDelegate = nil; web.loadHTMLString("<p>Offline mode is on.</p>", baseURL: nil) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !NetworkAccess.offline, let url = action.request.url else { decisionHandler(.cancel); return }
        if action.targetFrame?.isMainFrame != false, Self.isProjectPage(url) {
            completeSignIn(); decisionHandler(.cancel); return
        }
        decisionHandler(url.scheme == "https" ? .allow : .cancel)
    }
    deinit { if let networkLease { NetworkAccess.gate.release(networkLease) } }
    static func isProjectPage(_ url: URL) -> Bool {
        ["www.overleaf.com", "overleaf.com"].contains(url.host ?? "") && (url.path == "/project" || url.path.hasPrefix("/project/"))
    }
    static func isAuthenticatedProjectList(_ response: HTTPURLResponse) -> Bool {
        guard let url = response.url, ["www.overleaf.com", "overleaf.com"].contains(url.host ?? ""), url.path == "/user/projects", response.statusCode == 200 else { return false }
        return response.mimeType?.lowercased() == "application/json"
    }
    private func completeSignIn() { web.isHidden = true; signedIn = true }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, Self.isAuthenticatedProjectList(http) {
            completeSignIn(); decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
}

struct OverleafSignIn: View {
    @StateObject private var session: OverleafSignInSession
    let done: () -> Void
    let profile: UUID
    init(profile: UUID, done: @escaping () -> Void) { _session = StateObject(wrappedValue: OverleafSignInSession(profile: profile)); self.done = done; self.profile = profile }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Connect Overleaf account").font(RemileType.heading); Spacer(); Button("Done", action: done).keyboardShortcut(.cancelAction) }.padding(16)
            SignInWebView(web: session.web)
        }.frame(width: 740, height: 620).background(RemileStyle.background)
            .onChange(of: session.signedIn) { if session.signedIn { Task { await OverleafWebIdentity.remember(profile); done() } } }
    }
}
private struct SignInWebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ view: WKWebView, context: Context) { }
    static func dismantleNSView(_ view: WKWebView, coordinator: ()) { view.navigationDelegate = nil; view.stopLoading(); view.loadHTMLString("", baseURL: nil) }
}
