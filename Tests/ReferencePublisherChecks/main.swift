import AppKit
import PDFKit
import WebKit

@_cdecl("__isPlatformVersionAtLeast")
public func publisherHostVersion(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 { ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: Int(a), minorVersion: Int(b), patchVersion: Int(c))) ? 1 : 0 }
NSApplication.shared.setActivationPolicy(.prohibited)
var checks = 0
func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1; print("PASS: " + message); fflush(stdout) }
func response(_ mime: String, status: Int = 200, size: Int = 1000, url: String = "https://publisher.example.org/paper", disposition: String = "") -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": String(size), "Content-Disposition": disposition])!
}
func pdf(_ doi: String) -> Data {
    let bytes = NSMutableData(), consumer = CGDataConsumer(data: bytes)!
    var box = CGRect(x: 0, y: 0, width: 600, height: 800)
    let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: "Publisher session test paper"] as CFDictionary)!
    context.beginPDFPage(nil)
    let text = NSAttributedString(string: "doi:" + doi, attributes: [.font: NSFont.systemFont(ofSize: 12)])
    context.textPosition = CGPoint(x: 30, y: 700); CTLineDraw(CTLineCreateWithAttributedString(text), context)
    context.endPDFPage(); context.closePDF(); return bytes as Data
}
Task { @MainActor in
    do {
        let record = ReferenceRecord(fields: ["title": "Publisher session test paper", "doi": "10.1234/correct", "url": "https://publisher.example.org/article"])
        check(ReferencePublisherPolicy.source(record)?.host == "doi.org", "DOI opens the original publisher route")
        check(ReferencePublisherPolicy.source(ReferenceRecord(fields: ["url": "https://publisher.example.org/article"]))?.host == "publisher.example.org", "A source URL works without a DOI")
        check(ReferencePublisherPolicy.source(ReferenceRecord(fields: [:])) == nil, "No source means no connection action")
        check(ReferencePublisherPolicy.source(ReferenceRecord(fields: ["url": "file:///private/paper.pdf"])) == nil, "A local path cannot become a publisher website")
        check(ReferencePublisherPolicy.downloadable(response("application/pdf")), "Inline PDF responses are captured")
        check(ReferencePublisherPolicy.downloadable(response("application/octet-stream", disposition: "attachment; filename=paper.pdf")), "A binary download explicitly named PDF can be captured")
        check(!ReferencePublisherPolicy.downloadable(response("text/html")), "A login page stays a web page")
        check(!ReferencePublisherPolicy.downloadable(response("application/zip")), "Other attachment types are rejected")
        check(!ReferencePublisherPolicy.downloadable(response("application/pdf", status: 403)), "An access error cannot become an attachment")
        check(!ReferencePublisherPolicy.downloadable(response("application/pdf", size: ReferencePaperLookup.pdfLimit + 1)), "An advertised oversized download is rejected")
        check(!ReferencePublisherPolicy.downloadable(response("application/pdf", url: "http://publisher.example.org/paper")), "Insecure PDF downloads are rejected")
        check(!ReferencePublisherPolicy.downloadable(response("application/pdf", url: "https://127.0.0.1/paper")), "Local-network downloads are rejected")
        let source = URL(string: "https://publisher.example.org/paper.pdf")!
        let found = try ReferencePublisherPolicy.accepted(pdf("10.1234/correct"), source: source, record: record)
        check(found.source == source && found.version == "Publisher download", "A verified PDF returns to the existing attachment review")
        do { _ = try ReferencePublisherPolicy.accepted(pdf("10.1234/wrong"), source: source, record: record); check(false, "Wrong paper accepted") }
        catch { check(true, "A PDF from the wrong paper stays unattached") }
        do { _ = try ReferencePublisherPolicy.accepted(Data("<html>Log in</html>".utf8), source: source, record: record); check(false, "HTML accepted") }
        catch { check(true, "HTML named PDF stays unattached") }
        let session = ReferencePublisherSession(record: record, rememberSignIn: false)
        check(!session.web.configuration.websiteDataStore.isPersistent, "Publisher sign-in is window-scoped, not the Safari or Overleaf profile")
        check(session.web.url == nil && !session.loading, "Creating a session does not connect automatically")
        UserDefaults.standard.setVolatileDomain([NetworkAccessGate.preference: true], forName: UserDefaults.argumentDomain)
        session.start()
        check(session.issue != nil && session.web.url == nil, "Offline mode blocks the initial website request")
        session.stop(); session.stop()
        check(!session.receiving && !session.loading, "Repeated cancellation leaves the session stopped")
        let cookie = HTTPCookie(properties: [.name: "test-session", .value: "synthetic", .domain: "publisher.example.org", .path: "/", .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE"])!
        let saved = try ReferencePublisherIdentity.encode([cookie])
        let restored = try ReferencePublisherIdentity.decode(saved)
        check(restored.count == 1 && restored[0].value == "synthetic" && restored[0].isSecure, "A synthetic session cookie round-trips without a plaintext preferences entry")
        check(try ReferencePublisherIdentity.decode(saved, now: Date().addingTimeInterval(15 * 86400)).isEmpty, "A saved session is not restored after fourteen days")
        check(try ReferencePublisherIdentity.decode(Data(repeating: 0, count: 256 * 1024 + 1)).isEmpty, "Oversized saved sessions are rejected before decoding")
        UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        if CommandLine.arguments.contains("--online") {
            UserDefaults.standard.setVolatileDomain([NetworkAccessGate.preference: false], forName: UserDefaults.argumentDomain)
            let paper = ReferenceRecord(fields: ["title": "Attention Is All You Need", "eprint": "1706.03762v7", "url": "https://arxiv.org/pdf/1706.03762v7"])
            let browser = ReferencePublisherSession(record: paper, rememberSignIn: false); browser.start()
            let deadline = Date().addingTimeInterval(100)
            while browser.found == nil && browser.issue == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(250)) }
            let result = browser.found; let issue = browser.issue
            browser.stop()
            guard let result else { throw ReferenceFailure(issue ?? "The public WebKit download did not finish within the test budget.") }
            check(PDFDocument(data: result.data)?.pageCount == 15, "Real WebKit inline download returns the expected public PDF without manual file handling")
        }
        print("\(checks) publisher checks passed"); exit(0)
    } catch { fputs("Publisher check failed: \(error.localizedDescription)\n", stderr); exit(1) }
}
RunLoop.main.run()
