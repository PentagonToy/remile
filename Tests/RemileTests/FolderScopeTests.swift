import XCTest
@testable import Remile

final class FolderScopeTests: XCTestCase {
    private let parent = "11111111-1111-4111-8111-111111111111"
    private let child = "22222222-2222-4222-8222-222222222222"
    private let other = "33333333-3333-4333-8333-333333333333"
    private func folder(_ id: String, _ name: String, parent: String? = nil) -> RemarkableCloudItem {
        RemarkableCloudItem(id: id, title: name, revision: "one", parentID: parent, folder: true)
    }
    private func doc(_ id: String, parent: String? = nil) -> RemarkableCloudItem {
        RemarkableCloudItem(id: id, title: id, revision: "one", parentID: parent)
    }
    func testRemarkableFolderIdentityTracksNewDescendantsAndRenames() throws {
        let initial = [folder(parent, "Research"), folder(child, "Old name", parent: parent), folder(other, "Other"), doc("paper", parent: child), doc("outside", parent: other), doc("loose")]
        let scopes = try RemarkableFolderSelection.scopes([parent, child], items: initial)
        XCTAssertEqual(scopes.map(\.id), [parent])
        XCTAssertEqual(RemarkableFolderSelection.documents(scopes, items: initial), ["paper"])
        let newFolder = "44444444-4444-4444-8444-444444444444"
        let changed = [folder(parent, "Renamed"), folder(child, "Moved name", parent: parent), folder(newFolder, "New folder", parent: child), folder(other, "Other"), doc("paper", parent: child), doc("new", parent: parent), doc("new-nested", parent: newFolder), doc("outside", parent: other), doc("loose")]
        XCTAssertEqual(RemarkableFolderSelection.documents(scopes, items: changed), ["paper", "new", "new-nested"])
        XCTAssertEqual(RemarkableFolderSelection.documents([.init(id: RemarkableFolderScope.unfiledID, name: "Unfiled")], items: changed), ["loose"])
        XCTAssertTrue(RemarkableFolderSelection.documents(scopes, items: [folder(other, "Other"), doc("paper", parent: other)]).isEmpty)
    }
    func testFolderUpdateRetainsLocalTrashAndDisconnectFreezesImportedDocuments() {
        let libraryID = UUID()
        var library = ReferenceLibrary(id: libraryID, name: "reMarkable", source: "remarkable", remarkableFolders: [.init(id: parent, name: "Research")])
        var kept = ReferenceRecord(); kept.libraryID = libraryID; kept.remarkable = RemarkableReference(id: "old", revision: "one", title: "Old", fileType: "pdf")
        var removed = kept; removed.id = UUID(); removed.remarkable?.id = "deleted"; removed.trashed = Date()
        let items = [folder(parent, "Research"), doc("old", parent: parent), doc("new", parent: parent), doc("deleted", parent: parent), doc("outside")]
        XCTAssertEqual(RemarkableFolderSelection.updateIDs(library, records: [kept, removed], items: items), ["old", "new"])
        library.remarkableFolders = []
        XCTAssertTrue(RemarkableFolderSelection.updateIDs(library, records: [kept], items: items).isEmpty)
        library.remarkableFolders = nil
        XCTAssertEqual(RemarkableFolderSelection.updateIDs(library, records: [kept], items: items), ["old"])
    }
    func testSavedScopesAreUndoableWithoutRemovingExistingReferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ReferenceRepository(root: root).recordingHistory(ReferenceRepository.History())
        let scopes = [RemarkableFolderScope(id: parent, name: "Research")]
        let library = try repository.setRemarkableFolders(scopes)
        _ = try repository.add([ReferenceRecord(fields: ["title": "Existing paper"])], libraryID: library)
        _ = try repository.setRemarkableFolders([])
        XCTAssertEqual(try repository.libraries().first { $0.id == library }?.remarkableFolders, [])
        try repository.undo()
        XCTAssertEqual(try repository.libraries().first { $0.id == library }?.remarkableFolders, scopes)
        XCTAssertEqual(try repository.records().count, 1)
        try repository.undo(redo: true)
        XCTAssertEqual(try repository.records().count, 1)
        XCTAssertThrowsError(try repository.setRemarkableFolders([.init(id: "not-a-folder", name: "Invalid")]))
    }
    func testZoteroScopesExpandNewNestedCollectionsWithoutStoringNamesAsIdentity() throws {
        let library = ZoteroLibrary(path: "users/0", name: "My Library")
        let first = ZoteroCollection(key: "PARENT01", name: "Research", parent: nil)
        let child = ZoteroCollection(key: "CHILD001", name: "Child", parent: first.id)
        let new = ZoteroCollection(key: "NEWF0001", name: "New", parent: child.id)
        let scope = ZoteroScope(library: library, collection: first)
        let changed = ZoteroCollection(key: first.key, name: "Renamed", parent: nil)
        let expanded = try ZoteroFolderSelection.descendants(scope, collections: [changed, child, new])
        XCTAssertEqual(Set(expanded.map(\.id)), Set([scope.id, ZoteroScope(library: library, collection: child).id, ZoteroScope(library: library, collection: new).id]))
        XCTAssertEqual(ZoteroFolderSelection.canonical(Set(expanded.map(\.id)), scopes: expanded), [scope.id])
        XCTAssertThrowsError(try ZoteroFolderSelection.descendants(scope, collections: []))
    }
}
