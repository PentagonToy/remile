import AppKit
import PDFKit
import XCTest
@testable import Remile

final class ReferenceThesisTests: XCTestCase {
    func testBibTeXThesisKindsRoundTripWithUniversityAndDegree() throws {
        for kind in [ReferenceKind.mastersThesis, .doctoralThesis] {
            var source = ReferenceKind.note.applying(to: ReferenceRecord())
            source.key = "ExistingKey"
            source.fields["title"] = "A synthetic thesis title"
            source.fields["school"] = "Example University"
            source = kind.applying(to: source)
            XCTAssertNil(source.fields["entrysubtype"])
            let exported = try ReferenceBibTeX.export([source])
            let restored = try XCTUnwrap(ReferenceBibTeX.parse(exported).first)
            XCTAssertEqual(ReferenceKind.classify(restored), kind)
            XCTAssertEqual(restored.type, kind.bibType)
            XCTAssertEqual(restored.fields["school"], "Example University")
            XCTAssertEqual(restored.key, "ExistingKey")
        }
        let generic = ReferenceRecord(type: "thesis", fields: ["type": "mathesis"])
        XCTAssertEqual(ReferenceKind.classify(generic), .mastersThesis)
    }
    func testOnlyExplicitCoverDegreeStatementsClassifyTheses() {
        XCTAssertEqual(ReferencePDFMetadata.degree(in: "A dissertation submitted in partial fulfillment of the requirement for the degree of\nDoctor of Philosophy\nUniversity of Washington\n2006"), .doctoralThesis)
        XCTAssertEqual(ReferencePDFMetadata.degree(in: "by Cristopher Morales Ubal\nto obtain the degree of\nMaster of Science in Mechanical Engineering\nat the Delft University of Technology"), .mastersThesis)
        XCTAssertNil(ReferencePDFMetadata.degree(in: "An article about master thesis supervision"))
        XCTAssertNil(ReferencePDFMetadata.degree(in: "Abstract\nA dissertation submitted for the degree of Doctor of Philosophy is cited here."))
        XCTAssertNil(ReferencePDFMetadata.degree(in: "The author received the degree of Doctor of Philosophy in 2006."))
    }
    func testZoteroThesisDegreeIsNotAlwaysAssumedToBeDoctoral() throws {
        let library = ZoteroLibrary(path: "users/0", name: "Synthetic")
        for (degree, expected) in [("Master's thesis", "mastersthesis"), ("Ph.D.", "phdthesis"), ("", "thesis")] {
            let object: [String: Any] = ["key": "ABCD1234", "version": 1,
                "data": ["itemType": "thesis", "title": "Synthetic title", "thesisType": degree, "university": "Example University"]]
            let item = try JSONDecoder().decode(ZoteroItem.self, from: JSONSerialization.data(withJSONObject: object))
            let record = try item.reference(in: library)
            XCTAssertEqual(record.type, expected)
            XCTAssertEqual(record.fields["school"], "Example University")
        }
    }
    func testVerifiedDOICorrectsJournalMastheadButKeepsEditedTitle() throws {
        let fields = ["title": "Combustion and Flame", "journal": "Combustion and Flame", "author": "Author", "year": "2013", "doi": "10.1000/test"]
        var local = ReferenceRecord(type: "article", fields: fields)
        local.attachments = [ReferenceAttachment(name: "Synthetic.pdf", sha256: "synthetic", bytes: 1)]
        XCTAssertTrue(ReferenceRecognition.automaticEligible(local))
        let fetched = ReferenceRecord(type: "article", fields: ["title": "The actual paper title", "journal": "Combustion and Flame", "doi": "10.1000/test"])
        XCTAssertEqual(try ReferenceRecognition.merged(local, with: fetched).title, fetched.title)
        local.fields["title"] = "My edited title"
        XCTAssertEqual(try ReferenceRecognition.merged(local, with: fetched).title, local.title)
        var wrong = fetched
        wrong.fields["doi"] = "10.1000/other"
        XCTAssertThrowsError(try ReferenceRecognition.merged(local, with: wrong))
    }
    @MainActor func testJournalMastheadDoesNotWinOverTheArticleTitle() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("source.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(file as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (text, size, y) in [("Combustion and Flame", 24.0, 740.0), ("journal homepage: example.invalid", 10.0, 710.0), ("A verified synthetic article title", 18.0, 660.0), ("Abstract", 12.0, 610.0)] {
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size)]).draw(at: NSPoint(x: 40, y: y))
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage(); context.closePDF()
        let pdf = try XCTUnwrap(PDFDocument(url: file))
        pdf.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Combustion and Flame"]
        XCTAssertEqual(ReferencePDFMetadata.fields(pdf, fallback: "Fallback.pdf")["title"], "A verified synthetic article title")
    }
    @MainActor func testOrdinaryPDFImportUsesCoverDegreeEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cover.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(file as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let lines = ["A synthetic dissertation title", "A dissertation submitted in partial fulfillment", "of the requirement for the degree of", "Doctor of Philosophy"]
        for (index, line) in lines.enumerated() {
            NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 14)]).draw(at: NSPoint(x: 40, y: 700 - index * 30))
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage(); context.closePDF()
        let repository = ReferenceRepository(root: root.appendingPathComponent("Library"))
        let record = try XCTUnwrap(repository.importFiles([file]).first)
        XCTAssertEqual(ReferenceKind.classify(record), .doctoralThesis)
    }
}
