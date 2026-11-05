import AppKit
import CoreText
import PDFKit
import XCTest
@testable import Remile

final class ReferencePDFTitleTests: XCTestCase {
    private let productionTitle = "ef0c03685 1..66"
    private let articleTitle = "A synthetic study of reacting flows"

    func testProductionTitleUsesXMPOrPrintedTitle() throws {
        let embedded = try makePDF(infoTitle: productionTitle, xmpTitle: articleTitle)
        XCTAssertEqual(embedded.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, productionTitle)
        XCTAssertEqual(ReferencePDFMetadata.fields(embedded, fallback: "File name")["title"], articleTitle)

        let printed = try makePDF(infoTitle: productionTitle, printedTitle: articleTitle)
        XCTAssertEqual(ReferencePDFMetadata.fields(printed, fallback: "File name")["title"], articleTitle)

        let ordinary = try makePDF(infoTitle: "A report on material ef0c03685", xmpTitle: articleTitle)
        XCTAssertEqual(ReferencePDFMetadata.fields(ordinary, fallback: "File name")["title"], "A report on material ef0c03685")
    }

    func testCleanupRepairsStoredProductionTitleWithoutChangingCitationKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ef0c03685.pdf")
        let pdf = try makePDF(infoTitle: productionTitle, xmpTitle: articleTitle)
        try XCTUnwrap(pdf.dataRepresentation()).write(to: file)
        let repository = ReferenceRepository(root: root.appendingPathComponent("Library"))
        var record = try XCTUnwrap(repository.importFiles([file]).first)
        XCTAssertEqual(record.title, articleTitle)
        record.fields = ["title": productionTitle, "doi": "10.1000/example", "author": "Sample, A.", "year": "2021"]

        XCTAssertTrue(ReferenceRecognition.automaticEligible(record))
        let change = try XCTUnwrap(ReferenceCleanup.proposals([record], repository: repository).first)
        XCTAssertEqual(change.after.title, articleTitle)
        XCTAssertEqual(change.after.key, record.key)
        XCTAssertEqual(change.after.attachments, record.attachments)
        XCTAssertEqual(change.after.authors, record.authors)

        var fetched = record
        fetched.fields["title"] = articleTitle
        XCTAssertEqual(try ReferenceRecognition.merged(record, with: fetched).title, articleTitle)
        record.fields["title"] = "My edited title"
        XCTAssertEqual(try ReferenceRecognition.merged(record, with: fetched).title, record.title)
    }

    func testPaperLinkFollowsAdvertisedPDFWithoutStoringItsSignedURL() async throws {
        let page = URL(string: "https://papers.example.org/article")!
        let download = URL(string: "https://papers.example.org/main.pdf?X-Amz-Signature=sample")!
        let pdf = try XCTUnwrap(makePDF(infoTitle: articleTitle).dataRepresentation())
        let (record, found) = try await ReferencePDFResolver.fromLink(page, target: nil, load: { url, _ in
            if url == page {
                let html = """
                <meta name='citation_title' content='A synthetic study of reacting flows'>
                <meta name='citation_doi' content='10.1000/example'>
                <meta name='citation_pdf_url' content='\(download.absoluteString)'>
                """
                return .init(data: Data(html.utf8), url: url, html: true)
            }
            XCTAssertEqual(url, download)
            return .init(data: pdf, url: url, html: false)
        })
        XCTAssertEqual(record.title, articleTitle)
        XCTAssertNil(record.fields["url"])
        XCTAssertEqual(found?.data, pdf)

        let otherPaper = ReferenceRecord(fields: ["title": "A different paper about combustion"])
        do {
            _ = try await ReferencePDFResolver.fromLink(download, target: otherPaper, load: { url, _ in
                XCTAssertEqual(url, download)
                return .init(data: pdf, url: url, html: false)
            })
            XCTFail("A link to another paper must not attach to an existing reference.")
        } catch is ReferenceFailure {}
    }

    func testBrowserDownloadMustMatchSelectedPaper() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try XCTUnwrap(makePDF(infoTitle: articleTitle).dataRepresentation())
        try data.write(to: url)
        let selected = ReferenceRecord(fields: ["title": articleTitle])
        XCTAssertEqual(try ReferencePDFResolver.readLocal(url, for: selected), data)
        let other = ReferenceRecord(fields: ["title": "A different study about combustion"])
        XCTAssertThrowsError(try ReferencePDFResolver.readLocal(url, for: other))
    }

    func testWebLinkWithoutPDFImportsPageMetadata() async throws {
        let page = URL(string: "https://agency.example.org/air/no2?tracking=1")!
        let html = """
        <head>
        <link rel="canonical" href="/air/no2">
        <meta property="DC.title" content="Basic Information about NO2">
        <meta property="og:title" content="Basic Information about NO2 | Agency">
        <meta property="og:site_name" content="Environmental Agency">
        <meta property="DC.date.modified" content="2026-06-24">
        <meta property="article:published_time" content="2016-07-06T14:19:54-04:00">
        <script>const example = '<meta name="citation_pdf_url" content="/unrelated.pdf">';</script>
        </head>
        """
        let (record, found) = try await ReferencePDFResolver.fromLink(page, target: nil, load: { url, _ in
            XCTAssertEqual(url, page)
            return .init(data: Data(html.utf8), url: url, html: true)
        })
        XCTAssertNil(found)
        XCTAssertEqual(record.type, "online")
        XCTAssertEqual(record.title, "Basic Information about NO2")
        XCTAssertEqual(record.fields["organization"], "Environmental Agency")
        XCTAssertEqual(record.fields["date"], "2026-06-24")
        XCTAssertEqual(record.fields["year"], "2026")
        XCTAssertEqual(record.fields["url"], "https://agency.example.org/air/no2")
        XCTAssertNotNil(record.fields["urldate"])
        XCTAssertTrue(try ReferenceBibTeX.export([record]).hasPrefix("@online{"))
    }

    func testWebMetadataIsNotSavedForSignedLinksOrAsAnAttachment() async throws {
        let page = URL(string: "https://agency.example.org/air/no2")!
        let signed = URL(string: "https://agency.example.org/download?X-Amz-Signature=sample")!
        let html = Data("<title>Basic Information about NO2</title>".utf8)
        let target = ReferenceRecord(fields: ["title": "Basic Information about NO2"])
        for (url, record) in [(signed, nil), (page, target)] {
            do {
                _ = try await ReferencePDFResolver.fromLink(url, target: record, load: { _, _ in
                    .init(data: html, url: page, html: true)
                })
                XCTFail("This link must still require a PDF.")
            } catch is ReferenceFailure {}
        }
    }

    func testArticlePageRejectsAnAdvertisedPDFForAnotherPaper() async throws {
        let page = URL(string: "https://journal.example.org/article")!
        let html = """
        <meta name="citation_title" content="A synthetic study of reacting flows">
        <meta name="citation_journal_title" content="Example Journal">
        <meta name="citation_doi" content="10.1000/example">
        <meta name="citation_pdf_url" content="/wrong.pdf">
        """
        let wrong = try XCTUnwrap(makePDF(infoTitle: "An unrelated study of diffusion").dataRepresentation())
        let (record, found) = try await ReferencePDFResolver.fromLink(page, target: nil, load: { url, _ in
            if url == page { return .init(data: Data(html.utf8), url: url, html: true) }
            return .init(data: wrong, url: url, html: false)
        })
        XCTAssertNil(found)
        XCTAssertEqual(record.type, "article")
        XCTAssertEqual(record.fields["doi"], "10.1000/example")
    }

    func testScienceDirectArticleLinkUsesItsPublisherID() throws {
        let article = try XCTUnwrap(URL(string: "https://www.sciencedirect.com/science/article/pii/S1540748918306345?via%3Dihub"))
        let other = try XCTUnwrap(URL(string: "https://example.org/science/article/pii/S1540748918306345"))
        XCTAssertEqual(ReferencePaperLookup.scienceDirectPII(article), "S1540748918306345")
        XCTAssertNil(ReferencePaperLookup.scienceDirectPII(other))
    }

    func testPublisherAccessOpensCanonicalArticleWithoutLinkCredentials() throws {
        let url = try XCTUnwrap(URL(string: "https://sciencedirect.com/science/article/pii/S1540748918306345?tracking=sample#pdf"))
        let source = try XCTUnwrap(ReferencePublisherSource(url))
        XCTAssertEqual(source.article.absoluteString, "https://www.sciencedirect.com/science/article/pii/S1540748918306345")
        XCTAssertNil(ReferencePublisherSource(URL(string: "https://reader:secret@sciencedirect.com/science/article/pii/S1540748918306345")))
        XCTAssertNil(ReferencePublisherSource(URL(string: "https://sciencedirect.com.example.org/science/article/pii/S1540748918306345")))
        XCTAssertNil(ReferencePublisherSource(URL(string: "https://pdf.sciencedirectassets.com/main.pdf")))
    }

    func testPublisherDownloadRejectsErrorPagesAndOtherFileTypes() throws {
        let url = try XCTUnwrap(URL(string: "https://publisher.example.org/download"))
        func response(_ status: Int, _ type: String) throws -> HTTPURLResponse {
            try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type]))
        }
        XCTAssertTrue(ReferencePublisherSource.isPDFResponse(try response(200, "application/pdf")))
        XCTAssertTrue(ReferencePublisherSource.isPDFResponse(try response(200, "application/octet-stream"), filename: "paper.pdf"))
        XCTAssertFalse(ReferencePublisherSource.isPDFResponse(try response(403, "application/pdf")))
        XCTAssertFalse(ReferencePublisherSource.isPDFResponse(try response(200, "text/html"), filename: "paper.pdf"))
        XCTAssertFalse(ReferencePublisherSource.isPDFResponse(try response(200, "application/octet-stream"), filename: "data.zip"))
    }

    private func makePDF(infoTitle: String, xmpTitle: String? = nil, printedTitle: String? = nil) throws -> PDFDocument {
        let bytes = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: bytes)), mediaBox: &bounds, [kCGPDFContextTitle: infoTitle] as CFDictionary))
        if let xmpTitle {
            let xml = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
              <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
                  <dc:title><rdf:Alt>
                    <rdf:li xml:lang="fr">Un autre titre</rdf:li>
                    <rdf:li xml:lang="x-default">\(xmpTitle)</rdf:li>
                  </rdf:Alt></dc:title>
                </rdf:Description>
              </rdf:RDF>
            </x:xmpmeta>
            """
            context.addDocumentMetadata(Data(xml.utf8) as CFData)
        }
        context.beginPDFPage(nil)
        if let printedTitle {
            context.textPosition = CGPoint(x: 48, y: 700)
            let line = NSAttributedString(string: printedTitle, attributes: [.font: NSFont.systemFont(ofSize: 18)])
            CTLineDraw(CTLineCreateWithAttributedString(line), context)
        }
        context.endPDFPage()
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: bytes as Data))
    }
}
