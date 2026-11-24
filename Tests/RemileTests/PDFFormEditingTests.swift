import PDFKit
import XCTest
@testable import Remile

@MainActor final class PDFFormEditingTests: XCTestCase {
    private func fixture() -> Data {
        let blank = "<< /Type /XObject /Subtype /Form /BBox [0 0 228 25] /Resources << >> /Length 4 >>\nstream\nq Q\n\nendstream"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R 6 0 R 7 0 R] /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 4 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /Helv 4 0 R >> >> /Annots [5 0 R 6 0 R 7 0 R] >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) /Rect [72 650 300 675] /V () /DA (/Helv 12 Tf 0 g) /AP << /N 8 0 R >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /T (Approved) /Rect [72 610 90 628] /V /Off /AS /Off /AP << /N << /Yes 9 0 R /Off 10 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Ch /T (Level) /Rect [72 570 200 595] /Opt [(One) (Two)] /V (One) /DA (/Helv 12 Tf 0 g) /AP << /N 8 0 R >> >>",
            blank,
            "<< /Type /XObject /Subtype /Form /BBox [0 0 18 18] /Length 14 >>\nstream\n0 0 18 18 re f\n\nendstream",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 18 18] /Length 4 >>\nstream\nq Q\n\nendstream"
        ]
        var source = "%PDF-1.4\n", offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(source.utf8.count)
            source += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = source.utf8.count
        source += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { source += String(format: "%010d 00000 n \n", offset) }
        source += "trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(source.utf8)
    }
    private func file() throws -> URL {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remile-form-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Form.pdf")
        try fixture().write(to: url, options: .atomic)
        return url
    }
    private func field(_ name: String, in document: PDFDocument?) throws -> PDFAnnotation {
        try XCTUnwrap(document?.page(at: 0)?.annotations.first { $0.fieldName == name })
    }
    private func canonicalText(_ name: String, in document: PDFDocument) throws -> String? {
        let catalog = try XCTUnwrap(document.documentRef?.catalog)
        var form: CGPDFDictionaryRef?, fields: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form))
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(form), "Fields", &fields))
        let list = try XCTUnwrap(fields)
        XCTAssertEqual(CGPDFArrayGetCount(list), 3)
        for index in 0..<CGPDFArrayGetCount(list) {
            var entry: CGPDFDictionaryRef?, key: CGPDFStringRef?, value: CGPDFStringRef?
            guard CGPDFArrayGetDictionary(list, index, &entry), let entry,
                  CGPDFDictionaryGetString(entry, "T", &key), let key,
                  CGPDFStringCopyTextString(key) as String? == name else { continue }
            guard CGPDFDictionaryGetString(entry, "V", &value), let value else { return nil }
            return CGPDFStringCopyTextString(value) as String?
        }
        XCTFail("Missing canonical form field")
        return nil
    }
    func testSaveKeepsTextCheckboxAndChoiceValuesInteractive() async throws {
        let url = try file(), reader = ReadingSession()
        try reader.open(url, recordRecent: false)
        let session = PDFSession(); session.load(reader.bytes); reader.pdfSession = session
        defer { session.stop() }
        try field("Name", in: session.document).widgetStringValue = "Ada — 연구"
        try field("Approved", in: session.document).buttonWidgetState = .onState
        try field("Level", in: session.document).widgetStringValue = "Two"
        XCTAssertTrue(reader.dirty, "An immediate Save must not depend on a deferred notification")
        _ = try session.prepareSave()
        XCTAssertTrue(reader.save())
        for _ in 0..<4 { await Task.yield() }
        XCTAssertFalse(reader.dirty, "Notifications queued before Save must not make it dirty again")
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(try field("Name", in: reopened).widgetStringValue, "Ada — 연구")
        XCTAssertEqual(try canonicalText("Name", in: reopened), "Ada — 연구")
        XCTAssertEqual(try field("Approved", in: reopened).buttonWidgetState, .onState)
        XCTAssertEqual(try field("Level", in: reopened).widgetStringValue, "Two")
        XCTAssertEqual(try canonicalText("Level", in: reopened), "Two")
        XCTAssertEqual(reopened.page(at: 0)?.annotations.filter { $0.type == "Widget" }.count, 3)
        var annotations: CGPDFArrayRef?, annotation: CGPDFDictionaryRef?, appearance: CGPDFDictionaryRef?, stream: CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(reopened.documentRef?.page(at: 1)?.dictionary), "Annots", &annotations))
        XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(annotations), 0, &annotation))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(annotation), "AP", &appearance))
        XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(appearance), "N", &stream))
    }
    func testReplacingDocumentDetachesOldWidgetObservers() async throws {
        let session = PDFSession(), bytes = fixture()
        session.load(bytes)
        let old = try field("Name", in: session.document)
        old.widgetStringValue = "Old edit"
        session.discardChanges(to: bytes)
        old.widgetStringValue = "Detached edit"
        for _ in 0..<4 { await Task.yield() }
        XCTAssertFalse(session.hasPendingAnnotations || session.hasPendingFormEdits)
        try field("Name", in: session.document).widgetStringValue = "New edit"
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(session.hasPendingAnnotations)
        let reopened = try XCTUnwrap(PDFDocument(data: session.prepareSave()))
        XCTAssertEqual(try field("Name", in: reopened).widgetStringValue, "New edit")
        session.stop()
    }
    func testSaveUsesSerializedFormTreeWhenDocumentReferenceIsStale() throws {
        let bytes = fixture()
        let document = try XCTUnwrap(StaleFormDocument(data: bytes))
        let graph = PDFCommentGraph(document: document, sourceData: bytes)
        try field("Name", in: document).widgetStringValue = "Updated value"
        let original = bytes + Data("\n% Unedited field tree\n".utf8)
        document.originalReference = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: original as CFData))))
        XCTAssertEqual(try canonicalText("Name", in: document), "")
        let reopened = try XCTUnwrap(PDFDocument(data: graph.serialize(document)))
        XCTAssertEqual(try field("Name", in: reopened).widgetStringValue, "Updated value")
        XCTAssertEqual(try canonicalText("Name", in: reopened), "Updated value")
    }
    func testExternalRefreshPreservesUnsavedFormValues() async throws {
        let url = try file(), reader = ReadingSession()
        try reader.open(url, recordRecent: false)
        let session = PDFSession(); session.load(reader.bytes); reader.pdfSession = session
        defer { session.stop() }
        try field("Name", in: session.document).widgetStringValue = "Local form value"
        let remote = try XCTUnwrap(PDFDocument(data: fixture()))
        try field("Name", in: remote).widgetStringValue = "External form value"
        let remoteBytes = try XCTUnwrap(remote.dataRepresentation())
        try remoteBytes.write(to: url, options: .atomic)
        try await reader.refreshPDFFile()
        XCTAssertTrue(reader.pdfChangedOutside)
        XCTAssertEqual(try field("Name", in: session.document).widgetStringValue, "Local form value")
        XCTAssertEqual(try Data(contentsOf: url), remoteBytes)
        let copy = try XCTUnwrap(PDFDocument(data: session.prepareSave()))
        XCTAssertEqual(try field("Name", in: copy).widgetStringValue, "Local form value")
    }
}

private final class StaleFormDocument: PDFDocument {
    var originalReference: CGPDFDocument?
    override var documentRef: CGPDFDocument? { originalReference ?? super.documentRef }
}
