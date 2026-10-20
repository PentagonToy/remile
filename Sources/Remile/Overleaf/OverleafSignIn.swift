import SwiftUI
import WebKit

/// A short-lived authentication surface, never the document editor.
@MainActor final class OverleafSignInSession: NSObject, ObservableObject, WKNavigationDelegate {
    let web: WKWebView
    @Published var signedIn = false
    init(profile: UUID) {
        let config = WKWebViewConfiguration(); config.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile)
        web = WKWebView(frame: .zero, configuration: config)
        super.init(); web.navigationDelegate = self
        web.load(URLRequest(url: URL(string: "https://www.overleaf.com/login")!))
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.host == "www.overleaf.com", url.path == "/project" || url.path.hasPrefix("/project/") { signedIn = true; decisionHandler(.cancel); return }
        decisionHandler(url.scheme == "https" ? .allow : .cancel)
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
