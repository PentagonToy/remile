import XCTest
import SwiftUI
import PDFKit
@testable import Remile

final class RemarkableFolderTests: XCTestCase {
    private let items = [
        RemarkableCloudItem(id: "paper", title: "Same title", revision: "1", parentID: "nested"),
        RemarkableCloudItem(id: "root", title: "Same title", revision: "1"),
        RemarkableCloudItem(id: "nested", title: "Combustion", revision: "1", parentID: "books", folder: true),
        RemarkableCloudItem(id: "books", title: "Books", revision: "1", folder: true),
        RemarkableCloudItem(id: "empty", title: "Empty", revision: "1", folder: true),
    ]
    func testFoldersCollapseIndependentlyAndKeepRootDocuments() {
        XCTAssertEqual(RemarkableCloudTree.rows(items, expanded: [], query: "").map(\.id), ["books", "empty", "root"])
        XCTAssertEqual(RemarkableCloudTree.rows(items, expanded: ["books"], query: "").map(\.id), ["books", "nested", "empty", "root"])
        let rows = RemarkableCloudTree.rows(items, expanded: ["books", "nested"], query: "")
        XCTAssertEqual(rows.map(\.id), ["books", "nested", "paper", "empty", "root"])
        XCTAssertEqual(rows[2].depth, 2)
        XCTAssertEqual(rows[2].path, "My files / Books / Combustion")
    }
    func testSearchRevealsAncestorsAndDistinguishesIdenticalTitles() {
        let rows = RemarkableCloudTree.rows(items, expanded: [], query: "Same title")
        XCTAssertEqual(rows.map(\.id), ["books", "nested", "paper", "root"])
        XCTAssertNotEqual(rows[2].path, rows[3].path)
        XCTAssertEqual(RemarkableCloudTree.rows(items, expanded: [], query: "Combustion").map(\.id), ["books", "nested", "paper"])
        XCTAssertTrue(RemarkableCloudTree.rows(items, expanded: [], query: "absent").isEmpty)
    }
    func testMissingParentsDuplicatesAndCyclesRemainReachable() {
        let malformed = [
            RemarkableCloudItem(id: "a", title: "A", revision: "1", parentID: "b", folder: true),
            RemarkableCloudItem(id: "b", title: "B", revision: "1", parentID: "a", folder: true),
            RemarkableCloudItem(id: "orphan", title: "Orphan", revision: "1", parentID: "missing"),
        ]
        let rows = RemarkableCloudTree.rows(malformed + [malformed[0]], expanded: ["a", "b"], query: "")
        XCTAssertEqual(Set(rows.map(\.id)), ["a", "b", "orphan"])
        XCTAssertEqual(rows.count, 3)
    }
    func testLargeFolderSelectionsUseBoundedRequestsWithoutDroppingDocuments() {
        let ids = Set((0..<501).map { "document-" + String($0) })
        let batches = RemarkableCloudItem.selectionBatches(ids)
        XCTAssertEqual(batches.map(\.count), [200, 200, 101])
        XCTAssertEqual(batches.flatMap { $0 }, ids.sorted())
        XCTAssertTrue(RemarkableCloudItem.selectionBatches([]).isEmpty)
    }
    func testCloudModifiedDateUsesMillisecondsAndRejectsInvalidValues() {
        var item = items[0]
        item.modifiedTime = "1700000000000"
        XCTAssertEqual(item.modifiedDate?.timeIntervalSince1970, 1700000000)
        item.modifiedTime = "nan"
        XCTAssertNil(item.modifiedDate)
        item.modifiedTime = ""
        XCTAssertNil(item.modifiedDate)
    }
    @MainActor func testPickerLayoutInBothAppearances() throws {
        _ = NSApplication.shared
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            for query in ["", "Combustion"] {
                let root = RemarkableFolderPicker(items: items, query: query, busy: false, selection: .constant(["books"]))
                    .padding(16).frame(width: 820, height: 480).background(RemileStyle.background)
                let host = NSHostingView(rootView: root)
                host.appearance = NSAppearance(named: appearance)
                host.frame = NSRect(x: 0, y: 0, width: 820, height: 480)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                XCTAssertGreaterThan(bitmap.pixelsWide, 0)
                if let directory = ProcessInfo.processInfo.environment["REMILE_FOLDER_CAPTURE"] {
                    let suffix = query.isEmpty ? "collapsed" : "search"
                    let file = URL(fileURLWithPath: directory).appendingPathComponent(name + "-" + suffix + ".png")
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
                }
            }
        }
    }
    func testOlderDocumentRepliesStillDecode() throws {
        let item = try JSONDecoder().decode(RemarkableCloudItem.self, from: Data(#"{"id":"a","title":"Note","revision":"1"}"#.utf8))
        XCTAssertFalse(item.isFolder)
        XCTAssertNil(item.parentID)
    }
}
