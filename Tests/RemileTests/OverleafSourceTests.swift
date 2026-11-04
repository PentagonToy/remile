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
    func testDisjointEditsWithinOneParagraphMergeWithoutLosingUnicode() throws {
        let base = "The 🧭 alpha model uses stable chemistry and gamma transport.\n"
        let local = base.replacingOccurrences(of: "alpha", with: "ALPHA").replacingOccurrences(of: "gamma", with: "GAMMA")
        let remote = base.replacingOccurrences(of: "chemistry", with: "CHEMISTRY")
        let expected = local.replacingOccurrences(of: "chemistry", with: "CHEMISTRY")
        XCTAssertEqual(try OverleafSourceText.merge(base: base, local: local, remote: remote), expected)
        XCTAssertEqual(try OverleafSourceText.merge(base: base, local: remote, remote: local), expected)
        XCTAssertEqual(try OverleafSourceText.replacing(base, edits: OverleafSourceText.edits(from: base, to: local)), local)
        XCTAssertThrowsError(try OverleafSourceText.merge(base: base, local: local, remote: base.replacingOccurrences(of: "alpha", with: "another")))
        let large = String(repeating: "repeat ", count: 10_000)
        let changed = "start " + large + "end"
        let fallback = try OverleafSourceText.edits(from: large, to: changed)
        XCTAssertEqual(fallback.count, 1)
        XCTAssertEqual(try OverleafSourceText.replacing(large, edits: fallback), changed)
    }
    func testReplayOfAlreadyReceivedWordsKeepsNewLocalTypingOnce() throws {
        let base = "Local writing\nAnchor\n"
        let local = "Local writing revised\nAnchor remote\n"
        let remote = "Local writing\nAnchor remote\n"
        XCTAssertEqual(try OverleafSourceText.merge(base: base, local: local, remote: remote), local)
        XCTAssertEqual(try OverleafSourceText.merge(base: base, local: remote, remote: local), local)
        let longBase = String(repeating: "x", count: 40_000) + "END"
        let broadLocal = "prefix " + longBase + " remote"
        XCTAssertThrowsError(try OverleafSourceText.merge(base: longBase, local: broadLocal, remote: longBase + " remote"), "A budget fallback must pause rather than duplicate a received suffix")
    }
    func testUnambiguousSmallEditsAndIncrementalTailTypingMerge() throws {
        XCTAssertEqual(try OverleafSourceText.merge(base: "abcdef", local: "AbcdeF", remote: "abCdef"), "AbCdeF")
        XCTAssertEqual(try OverleafSourceText.merge(base: "abcdef", local: "abCdef", remote: "AbcdeF"), "AbCdeF")
        XCTAssertEqual(try OverleafSourceText.merge(base: "🧭abcdef", local: "🧭AbcdeF", remote: "🧭abCdef"), "🧭AbCdeF")
        let base = "I am typ"
        XCTAssertEqual(try OverleafSourceText.merge(base: base, local: base + "ing", remote: base + "ing a sentence."), base + "ing a sentence.")
        XCTAssertEqual(try OverleafSourceText.merge(base: base, local: base + "ing a sentence.", remote: base + "ing"), base + "ing a sentence.")
        XCTAssertThrowsError(try OverleafSourceText.merge(base: "abcdef", local: "abXdef", remote: "abYdef"))
    }
    func testLastLineContinuationAndSeparateAppendPreserveBothSides() throws {
        let base = "A 🧭 document\nI am typin"
        for newline in ["\n", "\r\n"] {
            let continuation = "g another sentence." + newline + newline
            let block = newline + "% separate note" + newline
            let expected = base + continuation + block
            XCTAssertEqual(try OverleafSourceText.merge(base: base, local: base + block, remote: base + continuation), expected)
            XCTAssertEqual(try OverleafSourceText.merge(base: base, local: base + continuation, remote: base + block), expected)
        }
        XCTAssertThrowsError(try OverleafSourceText.merge(base: base, local: base + "g left", remote: base + "g right"))
        XCTAssertThrowsError(try OverleafSourceText.merge(base: base, local: base + "\nfirst block", remote: base + "\nsecond block"))
        XCTAssertThrowsError(try OverleafSourceText.merge(base: base, local: base + "\nnew block", remote: base + "g first\nsecond paragraph"))
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
