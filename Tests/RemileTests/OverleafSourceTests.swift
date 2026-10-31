import Foundation
import XCTest
@testable import Remile

final class OverleafSourceTests: XCTestCase {
    func testBoundedEditsRoundTripUnicodeAndNewlines() throws {
        let cases = [("", "new"), ("gone", ""), ("a🧭b", "a🧪b"), ("e\u{301}\r\n", "e\u{301} changed\r\n"), ("same", "same"), ("last", "last\n")]
        for (before, after) in cases {
            let edit = try OverleafSource.Edit.between(before, after)
            XCTAssertEqual(try OverleafSourceText.replacing(before, edits: [edit]), after)
            XCTAssertEqual(try OverleafSourceText.replacing(before, edits: OverleafSourceText.edits(from: before, to: after)), after)
        }
        XCTAssertThrowsError(try OverleafSource.validate("binary\0data"))
        XCTAssertThrowsError(try OverleafSource.validate(String(repeating: "x", count: OverleafSource.textLimit + 1)))
    }
    func testIndependentSectionsMergeAndOverlapsRequireReview() throws {
        let base = "alpha\nkeep one\nbeta\nkeep two\ngamma\n"
        let local = "ALPHA\nkeep one\nbeta\nkeep two\nGAMMA\n"
        let remote = "alpha\nkeep one\nBETA\nkeep two\ngamma\n"
        let expected = "ALPHA\nkeep one\nBETA\nkeep two\nGAMMA\n"
        XCTAssertEqual(try OverleafSourceText.merge(base: base, local: local, remote: remote), expected)
        XCTAssertEqual(try OverleafSourceText.merge(base: base, local: local, remote: "ALPHA\nkeep one\nBETA\nkeep two\ngamma\n"), expected)
        XCTAssertEqual(try OverleafSourceText.merge(base: "alpha beta gamma", local: "ALPHA beta gamma", remote: "alpha beta GAMMA"), "ALPHA beta GAMMA")
        XCTAssertThrowsError(try OverleafSourceText.merge(base: "alpha", local: "Lalpha", remote: "Ralpha"))
        XCTAssertThrowsError(try OverleafSourceText.merge(base: base, local: local, remote: base.replacingOccurrences(of: "alpha", with: "other")))
        let edits = try OverleafSourceText.edits(from: local, to: remote)
        XCTAssertEqual(edits.count, 3)
        XCTAssertEqual(try OverleafSourceText.replacing(local, edits: [edits[1]]), expected)
    }
    func testComplexDiffFallsBackWithinItsBudget() throws {
        let before = (0..<2_001).map { "line \($0)\n" }.joined()
        let after = (0..<2_001).map { "changed \($0)\n" }.joined()
        let edits = try OverleafSourceText.edits(from: before, to: after)
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(try OverleafSourceText.replacing(before, edits: edits), after)
    }
    func testWriterIdentityLockAndSymlinkProtection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = OverleafSource.Key(profile: UUID(), project: String(repeating: "a", count: 24), document: String(repeating: "b", count: 24))
        try key.validate()
        XCTAssertThrowsError(try OverleafSource.Key(profile: key.profile, project: "../bad", document: key.document).validate())
        let lock = OverleafWriterLease.lock(for: key, under: directory)
        var owner: OverleafWriterLease? = try OverleafWriterLease(file: lock)
        XCTAssertThrowsError(try OverleafWriterLease(file: lock))
        withExtendedLifetime(owner) {}
        owner = nil
        let next = try OverleafWriterLease(file: lock)
        withExtendedLifetime(next) {}
        let link = directory.appendingPathComponent("linked.lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: lock)
        XCTAssertThrowsError(try OverleafWriterLease(file: link))
    }
    func testSourceScanRejectsUnsafePathsAndLinks() throws {
        for path in ["../escape", "/absolute", "a//b", ".git/config", "a/../b", "a\\b", "bad\nname"] {
            XCTAssertFalse(OverleafSourceFiles.validPath(path), path)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("source".utf8).write(to: root.appendingPathComponent("main.tex"))
        XCTAssertEqual(try OverleafSourceFiles.scan(root)["main.tex"], Data("source".utf8))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.tex"), withDestinationURL: root.appendingPathComponent("main.tex"))
        XCTAssertThrowsError(try OverleafSourceFiles.scan(root))
    }
}
