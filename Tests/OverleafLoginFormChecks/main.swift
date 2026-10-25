import AppKit
import WebKit

@MainActor final class LoginFixture: NSObject, WKNavigationDelegate {
    var loaded: CheckedContinuation<Void, Never>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.resume(); loaded = nil }
    func load(_ web: WKWebView, action: String = "/login", target: String = "", method: String = "post") async {
        await withCheckedContinuation { continuation in
            loaded = continuation; web.navigationDelegate = self
            web.loadHTMLString("""
            <form method="\(method)" action="\(action)" target="\(target)"><input name="email"><input type="password" name="password"><input name="_csrf" value="fixture-csrf"><button type="submit">Log in</button></form>
            <script>document.querySelector('form').addEventListener('submit', e => { e.preventDefault(); window.submitted = true; });</script>
            """, baseURL: URL(string: "https://www.overleaf.com/login")!)
        }
    }
}
@MainActor final class LoginNotice: NSObject, WKScriptMessageHandler {
    var received = false
    var waiter: CheckedContinuation<Void, Never>?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        precondition(message.body as? String == "browser")
        received = true; waiter?.resume(); waiter = nil
    }
    func wait() async { if !received { await withCheckedContinuation { waiter = $0 } } }
}
Task { @MainActor in
    var checks = 0
    func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
    expect(OverleafLoginForm.trusted(URL(string: "https://www.overleaf.com/login")), "Official HTTPS login is allowed")
    for value in ["http://www.overleaf.com/login", "https://www.overleaf.com:8443/login", "https://user@www.overleaf.com/login", "https://www.overleaf.com.attacker.invalid/login", "https://attacker.invalid/login", "https://www.overleaf.com/project"] {
        expect(!OverleafLoginForm.trusted(URL(string: value)), "Other credential destinations are refused")
    }
    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: .zero, configuration: config), fixture = LoginFixture()
    await fixture.load(web)
    do {
        let ready = try await web.callAsyncJavaScript(OverleafLoginForm.inspect, arguments: [:], in: nil, contentWorld: .page)
        expect(ready as? Bool == true, "Official form controls are recognised")
        let result = try await web.callAsyncJavaScript(OverleafLoginForm.submit, arguments: ["email": "fixture@example.invalid", "password": "fixture'\"\\ secret"], in: nil, contentWorld: .page)
        expect(result as? String == "submitted", "Native credentials submit the existing form")
        let values = try await web.callAsyncJavaScript("return [window.submitted === true, document.querySelector('[name=password]').value === expected, document.querySelector('[name=_csrf]').value === 'fixture-csrf'];", arguments: ["expected": "fixture'\"\\ secret"], in: nil, contentWorld: .page) as! [Bool]
        expect(values.allSatisfy { $0 }, "Credentials are argument-bound and CSRF is preserved")
        for (action, target, method) in [("https://attacker.invalid/login", "", "post"), ("/login", "_blank", "post"), ("/login", "", "get"), ("/register", "", "post")] {
            await fixture.load(web, action: action, target: target, method: method)
            let result = try await web.callAsyncJavaScript(OverleafLoginForm.submit, arguments: ["email": "fixture@example.invalid", "password": "fixture"], in: nil, contentWorld: .page)
            expect(result as? String == "browser", "Unsupported form falls back without credential submission")
            let untouched = try await web.callAsyncJavaScript("return document.querySelector('[name=password]').value === '' && window.submitted !== true;", arguments: [:], in: nil, contentWorld: .page)
            expect(untouched as? Bool == true, "Rejected forms never receive the password")
        }
        let notice = LoginNotice()
        config.userContentController.add(notice, name: "remileLogin")
        for html in ["<div role='alert'>Fixture login error</div>", "<input autocomplete='one-time-code'>"] {
            await fixture.load(web)
            notice.received = false
            _ = try await web.callAsyncJavaScript(OverleafLoginForm.observe, arguments: [:], in: nil, contentWorld: .page)
            _ = try await web.callAsyncJavaScript("document.body.insertAdjacentHTML('beforeend', html); return true;", arguments: ["html": html], in: nil, contentWorld: .page)
            await notice.wait()
            expect(notice.received, "Visible errors and extra verification request the browser without credentials in the message")
        }
        print("\(checks) native Overleaf login-form checks passed. Ephemeral HTML fixtures, no account request.")
        exit(0)
    } catch { print(error); exit(1) }
}
RunLoop.main.run()
