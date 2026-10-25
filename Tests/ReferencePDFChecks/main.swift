import AppKit
import PDFKit

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 { ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: Int(a), minorVersion: Int(b), patchVersion: Int(c))) ? 1 : 0 }
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
var checks = 0
func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1; print("PASS: " + message); fflush(stdout) }
func fixture(_ title: String, _ text: String) -> Data {
    let data = NSMutableData(), consumer = CGDataConsumer(data: data)!
    var box = CGRect(x: 0, y: 0, width: 600, height: 800)
    let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: title] as CFDictionary)!
    context.beginPDFPage(nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)]))
    context.textPosition = CGPoint(x: 40, y: 700); CTLineDraw(line, context)
    context.endPDFPage(); context.closePDF()
    return data as Data
}
actor Calls {
    var urls: [URL] = []
    func add(_ url: URL) { urls.append(url) }
    func read() -> [URL] { urls }
}
Task { @MainActor in
 do {
    UserDefaults.standard.setVolatileDomain([NetworkAccessGate.preference: false], forName: UserDefaults.argumentDomain)
    let title = "A careful study of reference metadata"
    let record = ReferenceRecord(fields: ["title": title, "doi": "10.1234/matching"])
    let good = fixture(title, "doi:10.1234/matching"), wrong = fixture("A different paper with different results", "doi:10.1234/wrong")
    check(try ReferencePDFResolver.validate(good, for: record), "Exact article DOI validates a readable PDF")
    check(try !ReferencePDFResolver.validate(wrong, for: record), "Conflicting DOI is rejected even from a trusted index")
    check(try !ReferencePDFResolver.validate(fixture("Supplementary materials for a careful study", "doi:10.1234/matching"), for: record), "A named supplement cannot replace the paper even with the same DOI")
    check(try !ReferencePDFResolver.validate(Data("<html>Sign in</html>".utf8), for: record), "HTML cannot be treated as a PDF")
    check(try !ReferencePDFResolver.validate(Data(repeating: 0, count: ReferencePaperLookup.pdfLimit + 1), for: record), "Oversized bytes cannot pass validation")
    var book = record; book.type = "book"
    check(try !ReferencePDFResolver.validate(fixture("A single chapter title", "doi:10.1234/matching"), for: book), "A book DOI in a chapter does not validate the whole book")
    check(try ReferencePDFResolver.validate(good, for: book), "Whole-book title and identifier can match")
    let archive = ReferenceRecord(fields: ["title": "Attention Is All You Need", "eprint": "1706.03762v7"])
    check(ReferencePDFResolver.seeds(archive).first?.url.absoluteString == "https://arxiv.org/pdf/1706.03762v7", "arXiv works without a DOI and preserves an explicit version")
    let archivePDF = fixture(archive.title, "arXiv:1706.03762v7")
    check(try ReferencePDFResolver.validate(archivePDF, for: archive), "An exact archive version validates")
    check(try !ReferencePDFResolver.validate(fixture(archive.title, "arXiv:1706.03762v6"), for: archive), "Another archive revision is rejected")
    let archiveDOI = ReferenceRecord(fields: ["doi": "10.48550/arXiv.1706.03762"])
    check(ReferencePDFResolver.seeds(archiveDOI).first?.url.host == "arxiv.org", "An arXiv DOI also has a direct public route")
    let landing = Data(#"<meta name='citation_pdf_url' content='/bad.pdf'><meta content='/good.pdf?token=a&amp;version=2' name='citation_pdf_url'><link rel='alternate' type='application/pdf' href='/third.pdf'>"#.utf8)
    let base = URL(string: "https://source.example.org/article")!
    let links = ReferencePaperLookup.landingPDFs(landing, base: base)
    check(links.count == 3 && links[1].query == "token=a&version=2", "Multiple explicit PDF links retain signed query parameters")
    let locations = try ReferencePDFResolver.parseLocations(Data(#"{"locations":[{"is_oa":true,"version":"submittedVersion","pdf_url":"https://repo.example.org/preprint.pdf"},{"is_oa":true,"version":"publishedVersion","pdf_url":"https://publisher.example.org/paper.pdf","landing_page_url":"https://publisher.example.org/article"},{"is_oa":false,"pdf_url":"https://closed.example.org/paper.pdf"}],"best_oa_location":{"is_oa":true,"version":"publishedVersion","pdf_url":"https://publisher.example.org/paper.pdf"}}"#.utf8))
    check(locations.count == 3 && locations[0].version == "Published version" && locations.last?.version == "Preprint", "Public locations are deduplicated, ranked by version and retain landing-page fallbacks")
    for raw in ["https://127.0.0.1/a", "https://0x7f.0.0.0x1/a", "https://private.local./a", "https://host.internal/a", "http://source.example.org/a", "file:///private/a", "https://user:secret@source.example.org/a"] {
        check(!ReferencePaperLookup.publicURL(URL(string: raw)!), "Unsafe source rejected: " + raw.components(separatedBy: "@").last!)
    }
    let calls = Calls()
    let found = try await ReferencePDFResolver.resolve(record, load: { url, _ in
        await calls.add(url)
        if url.host == "doi.org" { return .init(data: landing, url: base, html: true) }
        return .init(data: url.path == "/good.pdf" ? good : wrong, url: url, html: false)
    }, locations: { _, _ in preconditionFailure("Index should stay lazy after a successful source page") })
    check(found.data == good && found.source.query == "token=a&version=2", "A wrong first PDF falls through to a validated alternate")
    check(await calls.read().count == 3, "Successful discovery stops further downloads")
    let fallback = try await ReferencePDFResolver.resolve(record, load: { url, _ in
        if url.host == "doi.org" { throw URLError(.cannotConnectToHost) }
        return .init(data: good, url: url, html: false)
    }, locations: { _, _ in [.init(url: URL(string: "https://repository.example.org/paper.pdf")!, version: "Accepted manuscript")] })
    check(fallback.version == "Accepted manuscript", "Failed publisher retrieval falls back to an indexed repository with its version")
    let archiveFallback = try await ReferencePDFResolver.resolve(archive, load: { url, _ in
        if url.host == "arxiv.org" { throw URLError(.cannotConnectToHost) }
        return .init(data: archivePDF, url: url, html: false)
    }, locations: { doi, _ in
        precondition(doi == "10.48550/arxiv.1706.03762")
        return [.init(url: URL(string: "https://repository.example.org/archive.pdf")!)]
    })
    check(archiveFallback.data == archivePDF, "An arXiv-only record can fall back to a public repository without losing its requested revision")
    let throttled = Calls()
    let afterBusy = try await ReferencePDFResolver.resolve(record, load: { url, _ in
        await throttled.add(url)
        if url.host == "doi.org" { throw ReferencePDFTransfer.Busy(host: "publisher.example.org") }
        return .init(data: good, url: url, html: false)
    }, locations: { _, _ in [.init(url: URL(string: "https://publisher.example.org/alternate.pdf")!), .init(url: URL(string: "https://repository.example.org/paper.pdf")!)] })
    let busyCalls = await throttled.read()
    check(afterBusy.source.host == "repository.example.org" && busyCalls.count == 2, "A busy host is not retried through its alternate links")
    let onlyTitle = ReferenceRecord(fields: ["title": title])
    let titleFound = try await ReferencePDFResolver.resolve(onlyTitle, load: { url, _ in .init(data: good, url: url, html: false) }, locations: { _, _ in [] }, metadata: { _, _ in record })
    check(titleFound.data == good && onlyTitle.fields["doi"] == nil, "Exact title lookup can find a DOI without rewriting the catalogue record")
    do {
        _ = try await ReferencePDFResolver.resolve(onlyTitle, load: { _, _ in preconditionFailure("A mismatched title must not start a download") }, locations: { _, _ in [] }, metadata: { _, _ in ReferenceRecord(fields: ["title": "A completely unrelated publication", "doi": "10.1234/wrong"]) })
        check(false, "Mismatched metadata was accepted")
    } catch { check(true, "Title-only discovery refuses a different metadata record") }
    let loops = Calls()
    do {
        _ = try await ReferencePDFResolver.resolve(record, load: { url, _ in
            await loops.add(url)
            let next = url.appendingPathComponent("next")
            return .init(data: Data("<meta name='citation_pdf_url' content='\(next.absoluteString)'>".utf8), url: url, html: true)
        }, locations: { _, _ in [] })
        check(false, "A page loop must terminate")
    } catch { check(await loops.read().count == 8, "Discovery stops after eight retrieval attempts") }
    let cancelled = Task {
        try await ReferencePDFResolver.resolve(record, load: { _, _ in throw CancellationError() }, locations: { _, _ in preconditionFailure("Cancellation must not start a fallback") })
    }
    do { _ = try await cancelled.value; check(false, "Cancellation lost") } catch is CancellationError { check(true, "Cancellation propagates without fallback") }
    UserDefaults.standard.setVolatileDomain([NetworkAccessGate.preference: true], forName: UserDefaults.argumentDomain)
    do { _ = try await ReferencePDFTransfer.fetch(base, deadline: Date().addingTimeInterval(1)); check(false, "Offline request ran") }
    catch is NetworkAccessGate.Offline { check(true, "Airplane mode blocks retrieval before a session starts") }
    UserDefaults.standard.setVolatileDomain([NetworkAccessGate.preference: false], forName: UserDefaults.argumentDomain)
    do { _ = try await ReferencePDFTransfer.fetch(base, deadline: .distantPast); check(false, "Expired request started") }
    catch { check(true, "An expired search budget starts no session") }
    if let flag = CommandLine.arguments.firstIndex(of: "--public-fixture"), CommandLine.arguments.indices.contains(flag + 1) {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        check(try ReferencePDFResolver.validate(bytes, for: archive), "The saved public arXiv PDF passes the current identity and revision checks")
    }
    if CommandLine.arguments.contains("--online") {
        let live = try await ReferencePDFResolver.resolve(archive)
        check(live.data.prefix(5) == Data("%PDF-".utf8) && PDFDocument(data: live.data)?.pageCount == 15, "Public arXiv retrieval validates the requested paper and revision")
    }
    print("Passed \(checks) PDF acquisition checks"); exit(0)
 } catch { print("FAILED: \(error)"); exit(1) }
}
app.run()
