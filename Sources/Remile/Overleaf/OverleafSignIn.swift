import SwiftUI
import WebKit

/// A short-lived authentication surface, never the document editor.
@MainActor final class OverleafSignInSession: NSObject, ObservableObject, WKNavigationDelegate {
    let web: WKWebView
    private let profile: UUID
    private let fetchProjects: (UUID) async throws -> Data
    private let saveSession: (UUID) async -> Bool
    private let unlockSession: (UUID) async throws -> Void
    private var networkLease: UUID?
    private var check: Task<Void, Never>?
    @Published private(set) var signedIn = false
    @Published private(set) var checking = true
    @Published private(set) var issue: String?
    @Published private(set) var storageWarning: String?
    @Published private(set) var needsSessionAccess = false
    init(profile: UUID,
         fetchProjects: @escaping (UUID) async throws -> Data = { try await OverleafWebClient.request("/user/projects", profile: $0) },
         saveSession: @escaping (UUID) async -> Bool = { await OverleafWebIdentity.remember($0) },
         unlockSession: @escaping (UUID) async throws -> Void = { try NetworkAccess.requireOnline(); try await OverleafWebIdentity.restore($0, interactive: true) }) {
        self.profile = profile; self.fetchProjects = fetchProjects; self.saveSession = saveSession; self.unlockSession = unlockSession
        let config = WKWebViewConfiguration(); config.websiteDataStore = OverleafWebIdentity.dataStore(profile)
        web = WKWebView(frame: .zero, configuration: config)
        super.init(); web.navigationDelegate = self
        verifySession()
    }
    func verifySession(afterLogin: Bool = false, allowSavedSession: Bool = false) {
        check?.cancel(); checking = true; issue = nil; storageWarning = nil; needsSessionAccess = false
        web.navigationDelegate = self
        if let networkLease { NetworkAccess.gate.release(networkLease) }
        networkLease = try? NetworkAccess.gate.watch { [weak self] in Task { @MainActor in
            self?.stop(); self?.issue = NetworkAccessGate.Offline().localizedDescription
        } }
        check = Task { [weak self] in
            guard let self else { return }
            do {
                if allowSavedSession { try await unlockSession(profile); try Task.checkCancellation() }
                // A project-page redirect alone is not proof of authentication.
                _ = try OverleafWebClient.parseProjects(await fetchProjects(profile))
                try Task.checkCancellation()
                let saved = await saveSession(profile)
                try Task.checkCancellation()
                checking = false; web.isHidden = true
                if saved { signedIn = true }
                else { storageWarning = "Connected for now. Keychain could not save this session." }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                checking = false
                if (error as? OverleafWebClient.Failure) == .sessionLocked {
                    needsSessionAccess = true; issue = error.localizedDescription
                } else if let failure = error as? OverleafWebClient.Failure, failure.needsConnection {
                    if afterLogin { issue = failure.localizedDescription }
                    else { showLogin() }
                } else { issue = error.localizedDescription }
            }
        }
    }
    func signInAgain() {
        check?.cancel(); checking = false; needsSessionAccess = false; issue = nil; storageWarning = nil
        showLogin()
    }
    private func showLogin() {
        guard !NetworkAccess.offline else { issue = NetworkAccessGate.Offline().localizedDescription; return }
        web.isHidden = false
        web.load(URLRequest(url: URL(string: "https://www.overleaf.com/login")!))
    }
    func continueWithoutSaving() { signedIn = true }
    func stop() {
        check?.cancel(); checking = false; web.stopLoading(); web.navigationDelegate = nil
        if let networkLease { NetworkAccess.gate.release(networkLease); self.networkLease = nil }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !NetworkAccess.offline, let url = action.request.url else { decisionHandler(.cancel); return }
        if action.targetFrame?.isMainFrame != false, Self.isProjectPage(url) {
            decisionHandler(.cancel); verifySession(afterLogin: true); return
        }
        decisionHandler(url.scheme == "https" ? .allow : .cancel)
    }
    deinit { check?.cancel(); if let networkLease { NetworkAccess.gate.release(networkLease) } }
    static func isProjectPage(_ url: URL) -> Bool {
        ["www.overleaf.com", "overleaf.com"].contains(url.host ?? "") && (url.path == "/project" || url.path.hasPrefix("/project/"))
    }
    static func isAuthenticatedProjectList(_ response: HTTPURLResponse) -> Bool {
        guard let url = response.url, ["www.overleaf.com", "overleaf.com"].contains(url.host ?? ""), url.path == "/user/projects", response.statusCode == 200 else { return false }
        return response.mimeType?.lowercased() == "application/json"
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, Self.isAuthenticatedProjectList(http) {
            decisionHandler(.cancel); verifySession(afterLogin: true); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { issue = "Could not reach Overleaf. Check your connection, then retry." }
    }
}

struct OverleafSignIn: View {
    @StateObject private var session: OverleafSignInSession
    let done: () -> Void
    init(profile: UUID, done: @escaping () -> Void) { _session = StateObject(wrappedValue: OverleafSignInSession(profile: profile)); self.done = done }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Connect Overleaf account").font(RemileType.heading); Spacer(); Button("Done", action: done).keyboardShortcut(.cancelAction) }.padding(16)
            if session.checking {
                Spacer(); ProgressView("Checking saved session…"); Spacer()
            } else if let warning = session.storageWarning {
                Spacer(); Text(warning).font(RemileType.caption)
                Button("Continue") { session.continueWithoutSaving() }.padding(); Spacer()
            } else if let issue = session.issue {
                Spacer(); Text(issue).font(RemileType.caption).padding()
                if session.needsSessionAccess {
                    Button("Allow saved session") { session.verifySession(allowSavedSession: true) }
                    Button("Sign in again") { session.signInAgain() }.padding(.top, 8)
                } else { Button("Retry") { session.verifySession() } }
                Spacer()
            } else {
                SignInWebView(web: session.web)
                HStack {
                    Text("Sign in to browse projects.").font(RemileType.small).foregroundStyle(.secondary)
                    Spacer()
                    if FileManager.default.fileExists(atPath: "/System/Applications/Passwords.app") {
                        Button("Open Passwords") {
                            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Passwords.app"), configuration: NSWorkspace.OpenConfiguration())
                        }.remileHelp("Choose your saved Overleaf login")
                    }
                }.padding(12)
            }
        }.frame(width: 740, height: 620).background(RemileStyle.background)
            .onChange(of: session.signedIn) { if session.signedIn { done() } }
            .onDisappear { session.stop() }
    }
}
private struct SignInWebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ view: WKWebView, context: Context) { }
    static func dismantleNSView(_ view: WKWebView, coordinator: ()) { view.stopLoading() }
}
