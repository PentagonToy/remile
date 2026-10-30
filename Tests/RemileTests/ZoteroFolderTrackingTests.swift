import XCTest
@testable import Remile

private final class FolderAPIProtocol: URLProtocol {
    static var extended = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        var result: [[String: Any]] = []
        if path.hasSuffix("/collections") {
            result = [collection("PARENT01", name: Self.extended ? "Renamed" : "Research"), collection("CHILD001", name: "Child", parent: "PARENT01")]
            if Self.extended { result.append(collection("NEWF0001", name: "New", parent: "CHILD001")) }
        } else if path.contains("/collections/PARENT01/items/top") { result = [item("ITEM0001")] }
        else if path.contains("/collections/CHILD001/items/top") { result = [item("ITEM0001"), item("ITEM0002")] }
        else if path.contains("/collections/NEWF0001/items/top") { result = [item("ITEM0003")] }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Last-Modified-Version": "1"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: result))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    private func collection(_ key: String, name: String, parent: String? = nil) -> [String: Any] {
        ["key": key, "version": 1, "data": ["name": name, "parentCollection": parent as Any? ?? false]]
    }
    private func item(_ key: String) -> [String: Any] {
        ["key": key, "version": 1, "data": ["itemType": "book", "title": "Paper " + key]]
    }
}

final class ZoteroFolderTrackingTests: XCTestCase {
    @MainActor func testParentCollectionFindsNewNestedItemsAndPreservesExistingKeys() async throws {
        let old = UserDefaults.standard.object(forKey: ZoteroAccess.enabledKey)
        UserDefaults.standard.set(true, forKey: ZoteroAccess.enabledKey)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FolderAPIProtocol.extended = false
        defer {
            try? FileManager.default.removeItem(at: root)
            FolderAPIProtocol.extended = false
            if let old { UserDefaults.standard.set(old, forKey: ZoteroAccess.enabledKey) }
            else { UserDefaults.standard.removeObject(forKey: ZoteroAccess.enabledKey) }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FolderAPIProtocol.self]
        let browser = ZoteroExtensionModel(client: ZoteroLocalClient(session: URLSession(configuration: config)))
        let provider = ZoteroLibrary(path: "users/0", name: "My Library")
        let parent = ZoteroCollection(key: "PARENT01", name: "Research", parent: nil)
        browser.libraries = [provider]
        browser.collections[provider.id] = [parent, ZoteroCollection(key: "CHILD001", name: "Child", parent: parent.id)]
        let repository = ReferenceRepository(root: root)
        let references = ReferenceModel(repository: repository)
        var completed = false
        browser.importSelection([ZoteroScope(library: provider, collection: parent).id], to: references) { completed = true }
        for _ in 0..<600 where browser.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(browser.error)
        XCTAssertTrue(completed)
        XCTAssertEqual(try repository.records().count, 2)
        var local = try XCTUnwrap(repository.records().first)
        local.key = "my_key"
        local = try repository.update(local, expected: local.revision, renameKey: true)
        let library = try XCTUnwrap(repository.libraries().first { $0.source?.hasPrefix("zotero-import:") == true })
        FolderAPIProtocol.extended = true
        browser.updateLibrary(library, to: references)
        for _ in 0..<600 where browser.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(browser.error)
        XCTAssertEqual(try repository.records().count, 3)
        XCTAssertEqual(try repository.records().first { $0.id == local.id }?.key, "my_key")
        XCTAssertEqual(try repository.libraries().first { $0.id == library.id }?.name, "Research")
    }
}
