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
    private var loginTask: Task<Void, Never>?
    private var fallback: Task<Void, Never>?
    @Published private(set) var showingBrowser = false
    @Published private(set) var preparing = false
    @Published private(set) var submitting = false
    @Published private(set) var credentialIssue: String?
    private var attempt = UUID()
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
        config.userContentController.add(OverleafLoginMessages(session: self), name: "remileLogin")
        config.userContentController.addUserScript(WKUserScript(source: OverleafLoginForm.observe, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
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
                checking = false; submitting = false; preparing = false; fallback?.cancel(); web.isHidden = true
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
        showingBrowser = false; preparing = true; submitting = false; credentialIssue = nil
        web.isHidden = false
        web.load(URLRequest(url: URL(string: "https://www.overleaf.com/login")!))
    }
    func useBrowser() {
        attempt = UUID(); loginTask?.cancel(); fallback?.cancel(); submitting = false; credentialIssue = nil
        showingBrowser = true; web.isHidden = false
        if web.url == nil { web.load(URLRequest(url: URL(string: "https://www.overleaf.com/login")!)) }
    }
    func useEmail() {
        attempt = UUID(); loginTask?.cancel(); fallback?.cancel(); showingBrowser = false
        signInAgain()
    }
    func login(email: String, password: String) {
        guard !submitting, !preparing, !checking, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else { return }
        guard !NetworkAccess.offline else { credentialIssue = NetworkAccessGate.Offline().localizedDescription; return }
        guard OverleafLoginForm.trusted(web.url) else { useBrowser(); return }
        credentialIssue = nil; submitting = true
        let token = UUID(); attempt = token
        loginTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await web.callAsyncJavaScript(OverleafLoginForm.submit, arguments: ["email": email.trimmingCharacters(in: .whitespacesAndNewlines), "password": password], in: nil, contentWorld: .page)
                guard !Task.isCancelled, attempt == token, !signedIn else { return }
                if result as? String != "submitted" { useBrowser(); return }
                fallback = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                    guard let self, self.attempt == token, !self.signedIn, !self.checking else { return }
                    self.useBrowser()
                }
            } catch {
                guard !Task.isCancelled, attempt == token, !signedIn, !checking else { return }
                useBrowser()
            }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        preparing = false
        guard !showingBrowser else { return }
        guard OverleafLoginForm.trusted(webView.url), !submitting else { useBrowser(); return }
        let token = attempt
        loginTask = Task { [weak self] in
            guard let self else { return }
            let supported = try? await web.callAsyncJavaScript(OverleafLoginForm.inspect, arguments: [:], in: nil, contentWorld: .page)
            guard !Task.isCancelled, attempt == token, !signedIn else { return }
            if supported as? Bool != true { useBrowser() }
        }
    }
    func continueWithoutSaving() { signedIn = true }
    func stop() {
        attempt = UUID(); loginTask?.cancel(); fallback?.cancel(); submitting = false; preparing = false
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
    deinit { check?.cancel(); loginTask?.cancel(); fallback?.cancel(); if let networkLease { NetworkAccess.gate.release(networkLease) } }
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
        if (error as NSError).code != NSURLErrorCancelled { preparing = false; submitting = false; issue = "Could not reach Overleaf. Check your connection, then retry." }
    }
}

@MainActor private final class OverleafLoginMessages: NSObject, WKScriptMessageHandler {
    weak var session: OverleafSignInSession?
    init(session: OverleafSignInSession) { self.session = session }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == "https",
              ["www.overleaf.com", "overleaf.com"].contains(message.frameInfo.securityOrigin.host), message.body as? String == "browser" else { return }
        session?.useBrowser()
    }
}

@MainActor private final class OverleafLoginDraft: ObservableObject {
    @Published var email = ""
    @Published var password = ""
}

struct OverleafSignIn: View {
    @StateObject private var session: OverleafSignInSession
    @StateObject private var draft = OverleafLoginDraft()
    let done: () -> Void
    init(profile: UUID, done: @escaping () -> Void) { _session = StateObject(wrappedValue: OverleafSignInSession(profile: profile)); self.done = done }
    private func openPasswords() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Passwords.app"), configuration: NSWorkspace.OpenConfiguration())
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connect Overleaf").font(RemileType.heading)
                Spacer()
                Button("Close", action: done).keyboardShortcut(.cancelAction)
            }.padding(20)
            ZStack {
                SignInWebView(web: session.web).opacity(session.showingBrowser && !session.checking ? 1 : 0)
                    .allowsHitTesting(session.showingBrowser && !session.checking)
                    .accessibilityHidden(!session.showingBrowser || session.checking)
                if session.checking {
                    RemileStyle.background
                    ProgressView("Checking saved session…")
                } else if let warning = session.storageWarning {
                    RemileStyle.background
                    VStack(spacing: 16) { Text(warning).font(RemileType.caption); Button("Continue") { session.continueWithoutSaving() } }.padding(28)
                } else if let issue = session.issue {
                    RemileStyle.background
                    VStack(spacing: 16) {
                        Text(issue).font(RemileType.caption).multilineTextAlignment(.center)
                        if session.needsSessionAccess {
                            Button("Allow saved session") { session.verifySession(allowSavedSession: true) }
                            Button("Sign in again") { session.signInAgain() }
                        } else { Button("Retry") { session.verifySession() } }
                    }.padding(28)
                } else if !session.showingBrowser {
                    RemileStyle.background
                    VStack(spacing: 16) {
                        VStack(spacing: 0) {
                            TextField("Email", text: $draft.email).textContentType(.username).padding(12)
                            Divider().padding(.horizontal, 12)
                            HStack(spacing: 8) {
                                SecureField("Password", text: $draft.password).textContentType(.password)
                                if FileManager.default.fileExists(atPath: "/System/Applications/Passwords.app") {
                                    Button { openPasswords() } label: { Label("Apple Passwords", systemImage: "key.fill") }
                                        .buttonStyle(.plain).font(RemileType.small).foregroundStyle(RemileStyle.accent)
                                        .fixedSize().help("Open Apple Passwords to choose your Overleaf login")
                                }
                            }.padding(12)
                        }.textFieldStyle(.plain).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(RemileStyle.ink.opacity(0.10), lineWidth: 1))
                            .disabled(session.submitting)
                        Button {
                            let secret = draft.password; draft.password = ""; session.login(email: draft.email, password: secret)
                        } label: {
                            HStack(spacing: 8) {
                                Spacer()
                                if session.preparing || session.submitting { ProgressView().controlSize(.small) }
                                Text(session.submitting ? "Signing in…" : "Sign in")
                                Spacer()
                            }.padding(.vertical, 4)
                        }.buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle).controlSize(.large).keyboardShortcut(.defaultAction)
                            .disabled(session.preparing || session.submitting || draft.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.password.isEmpty)
                        if let issue = session.credentialIssue { Text(issue).font(RemileType.small).foregroundStyle(.secondary) }
                        HStack {
                            Button("Forgot password?") { draft.password = ""; session.useBrowser(); session.web.load(URLRequest(url: URL(string: "https://www.overleaf.com/user/password/reset")!)) }
                            Spacer()
                            Button("Other ways…") { draft.password = ""; session.useBrowser() }.help("Google, ORCID, IEEE or institutional sign-in")
                        }.buttonStyle(.plain).font(RemileType.small).foregroundStyle(RemileStyle.accent)
                        Text("Password not saved by remile.").font(RemileType.small).foregroundStyle(.secondary)
                    }.padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                }
            }
            if session.showingBrowser && !session.checking && session.issue == nil && session.storageWarning == nil {
                HStack { Button("Use email and password") { draft.password = ""; session.useEmail() }; Spacer(); Text("Continue securely on Overleaf.").font(RemileType.small).foregroundStyle(.secondary) }.padding(16)
            }
        }.frame(width: session.showingBrowser ? 740 : 460, height: session.showingBrowser ? 640 : 340)
            .background(RemileStyle.background).foregroundStyle(RemileStyle.ink).tint(RemileStyle.accent).font(RemileType.caption)
            .onChange(of: session.signedIn) { if session.signedIn { draft.password = ""; done() } }
            .onChange(of: session.issue) { if $0 != nil { draft.password = "" } }
            .onChange(of: session.showingBrowser) { if $0 { draft.password = "" } }
            .onDisappear { draft.password = ""; session.stop() }
    }
}
private struct SignInWebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ view: WKWebView, context: Context) { }
    static func dismantleNSView(_ view: WKWebView, coordinator: ()) { view.stopLoading() }
}
