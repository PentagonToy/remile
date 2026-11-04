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
