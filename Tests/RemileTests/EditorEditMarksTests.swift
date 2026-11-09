import Foundation
import XCTest
@testable import Remile

final class EditorEditMarksTests: XCTestCase {
    private let first = "The experiment measures cold-flow stability along the inlet."
    private let second = "The reaction rate follows a separate pressure-dependent law."
    private var source: String { "\\section{Methods}\n" + first + " " + second + "\nEnd of the report." }

    func testPartialRecoveryWithTwoChangesInTheSameParagraph() {
        let original = source as NSString
        let marked = [original.range(of: first), original.range(of: second)]
        let snapshot = EditorEditMarks.Snapshot(source: source, ranges: marked)
        XCTAssertEqual(snapshot.restore(in: source), marked)
        let changed = "% 협업자 🌊\n" + source.replacingOccurrences(of: first, with: "The inlet was removed by a collaborator.")
            .replacingOccurrences(of: "End of the report.", with: "Appendix added.")
        XCTAssertEqual(snapshot.restore(in: changed), [(changed as NSString).range(of: second)])

        var tracker = EditorProvenance.Tracker(ranges: marked)
        tracker.transition(before: source, after: changed, preserveUnchanged: true)
        XCTAssertEqual(tracker.ranges, [(changed as NSString).range(of: second)])
    }

    func testDuplicateAnchorsAreSkippedAndCorruptRangesAreIgnored() {
        let text = first + "\n" + second
        let marked = (text as NSString).range(of: second)
        let snapshot = EditorEditMarks.Snapshot(source: text, ranges: [marked, NSRange(location: 1, length: Int.max)])
        XCTAssertEqual(snapshot.restore(in: text), [marked])
        XCTAssertTrue(snapshot.restore(in: text + "\n" + second).isEmpty)
    }

    func testOneMarkedPassageKeepsItsUnchangedEnds() {
        let start = "abcdefghijklmnopqrstuvwx"
        let end = "012345678901234567890123"
        let text = start + "ABCDEFGHIJKLMNOPQRSTUVWX" + end
        let snapshot = EditorEditMarks.Snapshot(source: text, ranges: [NSRange(location: 0, length: text.utf16.count)])
        let edited = start + "A collaborator replaced these words." + end
        XCTAssertEqual(snapshot.restore(in: edited), [(edited as NSString).range(of: start), (edited as NSString).range(of: end)])
    }

    func testOneAgentRequestKeepsSeparateSmallChanges() {
        let before = "Alpha stays unchanged in this middle sentence. Beta"
        let after = "Omega stays unchanged in this middle sentence. Zeta"
        var tracker = EditorProvenance.Tracker()
        tracker.mark(before: before, after: after)
        let middle = (after as NSString).range(of: " stays unchanged in this middle sentence. ")
        XCTAssertGreaterThanOrEqual(tracker.ranges.count, 2)
        XCTAssertTrue(tracker.ranges.allSatisfy { NSIntersectionRange($0, middle).length == 0 })
    }

    @MainActor func testLaTeXSaveMoveAndReopenRestoresBackgroundFileWithoutOpeningATab() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = EditorEditMarks.Store(directory: folder.appendingPathComponent("marks"))
        let root = folder.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "\\documentclass{article}\n\\begin{document}Main\\end{document}".write(to: root.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        let file = "section.tex"
        let before = "\\section{Methods}\n", after = before + second
        try before.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        let project = try TeXProject(root, historyEnabled: false, editMarkStore: store)
        XCTAssertTrue(project.applyTool(file: file, before: before, after: after, name: "CLI edit", feedback: false, reveal: false))
        project.markExternalEdit(file: file, before: before, after: after)
        XCTAssertNil(store.read(for: root.appendingPathComponent(file)))
        XCTAssertTrue(project.save())
        let moved = "renamed.tex"
        XCTAssertTrue(project.move(file, to: moved))
        XCTAssertNil(store.read(for: root.appendingPathComponent(file)))
        let remote = "% New heading\n" + after + "\nA new conclusion."
        let plan = TeXProject.LiveFileInstall(root: root, editRevision: project.editRevision, fileRevision: project.fileRevision,
                                              expected: [moved: Data(after.utf8)], result: [moved: Data(remote.utf8)],
                                              paths: [moved], moved: [:], matchesRemote: true)
        try project.installLiveFiles(plan)
        XCTAssertEqual(project.editRanges(in: moved), [(remote as NSString).range(of: second)])
        let changed = remote.replacingOccurrences(of: "% New heading", with: "% A collaborator added a longer heading")
        try changed.write(to: root.appendingPathComponent(moved), atomically: true, encoding: .utf8)
        let reopened = try TeXProject(root, historyEnabled: false, editMarkStore: store)
        XCTAssertEqual(reopened.editRanges(in: moved), [(changed as NSString).range(of: second)])
        XCTAssertEqual(reopened.openFiles, ["main.tex"])
    }

    @MainActor func testMarkdownSaveAndReopenKeepsUnchangedMarkedText() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("report.md")
        let store = EditorEditMarks.Store(directory: folder.appendingPathComponent("marks"))
        let before = "# Methods\n", after = before + second
        try before.write(to: url, atomically: true, encoding: .utf8)
        let session = ReadingSession(editMarkStore: store)
        try session.open(url, recordRecent: false)
        XCTAssertTrue(session.replaceMarkdown(before: before, after: after, undoManager: nil))
        session.markExternalEdit(before: before, after: after)
        XCTAssertTrue(session.save())
        let changed = "# Results\n" + second
        try changed.write(to: url, atomically: true, encoding: .utf8)
        let reopened = ReadingSession(editMarkStore: store)
        try reopened.open(url, recordRecent: false)
        XCTAssertEqual(reopened.externalEdits, [(changed as NSString).range(of: second)])
        let bytes = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil).first)
        let metadata = try String(contentsOf: bytes, encoding: .utf8)
        XCTAssertFalse(metadata.contains(second))
        XCTAssertLessThan(metadata.utf8.count, 64_000)
    }

    @MainActor func testTwoMacsShareOverleafMarksWithoutRepublishingEachOthersRanges() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = folder.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try Data(#"{"schema":1}"#.utf8).write(to: storage.appendingPathComponent("remile-storage.json"))
        let firstMac = EditorEditMarks.Shared(root: storage, machine: UUID().uuidString, project: "same-project")
        let secondMac = EditorEditMarks.Shared(root: storage, machine: UUID().uuidString, project: "same-project")
        let firstRoot = folder.appendingPathComponent("first")
        let secondRoot = folder.appendingPathComponent("second")
        let file = "main.tex"
        let before = "\\documentclass{article}\n\\begin{document}\n"
        let authored = before + second
        for root in [firstRoot, secondRoot] { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        try before.write(to: firstRoot.appendingPathComponent(file), atomically: true, encoding: .utf8)
        let firstProject = try TeXProject(firstRoot, historyEnabled: false,
                                         editMarkStore: .init(directory: folder.appendingPathComponent("first-marks")), sharedEditMarks: firstMac)
        XCTAssertTrue(firstProject.applyTool(file: file, before: before, after: authored, name: "CLI edit", feedback: false))
        firstProject.markExternalEdit(file: file, before: before, after: authored)
        XCTAssertTrue(firstProject.save())

        let adjusted = "% Overleaf change\n" + authored
        try adjusted.write(to: secondRoot.appendingPathComponent(file), atomically: true, encoding: .utf8)
        let secondProject = try TeXProject(secondRoot, historyEnabled: false,
                                          editMarkStore: .init(directory: folder.appendingPathComponent("second-marks")), sharedEditMarks: secondMac)
        let foreign = (adjusted as NSString).range(of: second)
        XCTAssertEqual(secondProject.editRanges(in: file), [foreign])
        XCTAssertNil(secondMac.ownSnapshot(for: file))

        let secondEdit = adjusted + first
        XCTAssertTrue(secondProject.applyTool(file: file, before: adjusted, after: secondEdit, name: "CLI edit", feedback: false))
        secondProject.markExternalEdit(file: file, before: adjusted, after: secondEdit)
        XCTAssertTrue(secondProject.save())
        let own = (secondEdit as NSString).range(of: first)
        XCTAssertEqual(secondMac.ownSnapshot(for: file)?.restore(in: secondEdit), [own])
        XCTAssertEqual(secondProject.editRanges(in: file), [NSUnionRange(foreign, own)])
        XCTAssertEqual(firstMac.ownSnapshot(for: file)?.restore(in: authored), [(authored as NSString).range(of: second)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstRoot.appendingPathComponent(StorageLocation.overleafMarksFolder).path))
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EditMarks-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
