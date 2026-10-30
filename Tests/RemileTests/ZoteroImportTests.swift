import XCTest
import PDFKit
@testable import Remile

private final class ZoteroImportProtocol: URLProtocol {
    static var pdfURL: URL?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: String
        if path.hasSuffix("/items/top") {
            body = #"[{"key":"ABCD1234","version":1,"data":{"itemType":"journalArticle","title":"Imported paper","DOI":"10.1000/test","date":"2026","creators":[{"creatorType":"author","lastName":"Author"}]}}]"#
        } else if path.hasSuffix("/children") {
            body = #"[{"key":"PDFKEY01","version":1,"data":{"itemType":"attachment","contentType":"application/pdf"}}]"#
        } else if path.hasSuffix("/file/view/url") { body = Self.pdfURL?.absoluteString ?? "https://example.com/forbidden.pdf" }
        else { body = "[]" }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Last-Modified-Version": "1"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ZoteroImportTests: XCTestCase {
    private func client() -> ZoteroLocalClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ZoteroImportProtocol.self]
        return ZoteroLocalClient(session: URLSession(configuration: config))
    }
    @MainActor func testSelectedSourceImportsThroughTheLocalAPIAndSharesItsPDF() async throws {
        let previous = UserDefaults.standard.object(forKey: ZoteroAccess.enabledKey)
        UserDefaults.standard.set(true, forKey: ZoteroAccess.enabledKey)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            ZoteroImportProtocol.pdfURL = nil
            if let previous { UserDefaults.standard.set(previous, forKey: ZoteroAccess.enabledKey) }
            else { UserDefaults.standard.removeObject(forKey: ZoteroAccess.enabledKey) }
        }
        let file = folder.appendingPathComponent("fixture.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = try XCTUnwrap(CGContext(file as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        ZoteroImportProtocol.pdfURL = file
        let original = try Data(contentsOf: file)
        let repository = ReferenceRepository(root: folder.appendingPathComponent("Library"), keyRule: .surnameYearWord)
        let local = try XCTUnwrap(repository.add([ReferenceRecord(fields: ["title": "My local paper", "doi": "10.1000/test"])]).first)
        let references = ReferenceModel(repository: repository)
        let model = ZoteroExtensionModel(client: client())
        let library = ZoteroLibrary(path: "users/0", name: "My Library")
        model.libraries = [library]
        var completed = false
        model.importSelection([ZoteroScope(library: library).id], to: references) { completed = true }
        for _ in 0..<600 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.error)
        XCTAssertTrue(completed)
        let records = try repository.records()
        let imported = try XCTUnwrap(records.first { $0.id != local.id })
        XCTAssertEqual(imported.key, "ABCD1234")
        XCTAssertEqual(imported.attachments.count, 1)
        XCTAssertEqual(records.first { $0.id == local.id }?.attachments, imported.attachments)
        XCTAssertEqual(try Data(contentsOf: file), original)
        var edited = imported
        edited.key = "my_local_key"
        _ = try repository.update(edited, expected: imported.revision, renameKey: true)
        let storedLibrary = try XCTUnwrap(repository.libraries().first { $0.id == imported.library })
        model.updateLibrary(storedLibrary, to: references)
        for _ in 0..<600 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.error)
        XCTAssertEqual(try repository.records().count, 2)
        XCTAssertEqual(try repository.records().first { $0.id == imported.id }?.key, "my_local_key")
    }
    func testPDFEndpointCannotRedirectTheImporterToAnInternetFile() async throws {
        ZoteroImportProtocol.pdfURL = nil
        let pdf = try JSONDecoder().decode(ZoteroItem.self, from: Data(#"{"key":"PDFKEY01","version":1,"data":{"itemType":"attachment","contentType":"application/pdf"}}"#.utf8))
        do {
            _ = try await client().localPDF(pdf, in: ZoteroLibrary(path: "users/0", name: "My Library"))
            XCTFail("A remote file URL must not be accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("local PDF")) }
    }
}
