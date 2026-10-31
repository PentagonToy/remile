import Foundation
import XCTest
@testable import Remile

final class OverleafGitSyncTests: XCTestCase {
    func testReviewDatesAcceptFractionalAndWholeSeconds() throws {
        let whole = try XCTUnwrap(OverleafReviewSnapshot.date("2026-10-31T06:35:00Z"))
        let fraction = try XCTUnwrap(OverleafReviewSnapshot.date("2026-10-31T06:35:00.123Z"))
        XCTAssertEqual(fraction.timeIntervalSince(whole), 0.123, accuracy: 0.001)
        XCTAssertNil(OverleafReviewSnapshot.date("not a date"))
    }
    func testChangeAuthorsUseNamesWithoutEmailFallback() throws {
        let connection = OverleafConnection(id: UUID(), projectID: String(repeating: "a", count: 24), name: "Fixture", account: "Test", branch: "main")
        let archive = try OverleafThreadArchive.parse(Data("{}".utf8), project: connection)
        var snapshot = OverleafReviewSnapshot(archive: archive)
        let payload = Data(#"{"pathname":"main.tex","lines":["body"],"ranges":{"changes":[{"id":"c1","op":{"p":0,"d":"old"},"metadata":{"user_id":"u1"}},{"id":"c2","op":{"p":0,"d":"old"},"metadata":{"user_id":"u2"}}]}}"#.utf8)
        try snapshot.include(payload, documentID: "doc1")
        try snapshot.includeAuthors(Data(#"[{"id":"u1","first_name":"Hanseul","last_name":"Kang","email":"private@example.com"},{"id":"u2","email":"private@example.com"}]"#.utf8))
        XCTAssertEqual(snapshot.changes.first?.author, "Hanseul Kang")
        XCTAssertNil(snapshot.changes.last?.author)
        let exported = String(decoding: try snapshot.export(json: true), as: UTF8.self)
        XCTAssertTrue(exported.contains("Hanseul Kang"))
        XCTAssertFalse(exported.contains("private@example.com"))
    }
    @MainActor func testSyncScheduleBacksOffAndCoalescesEdits() {
        XCTAssertEqual((0...6).map { OverleafLiveWorkspace.idleDelay(unchangedChecks: $0) }, [60, 60, 120, 240, 300, 300, 300])
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(OverleafLiveWorkspace.editDeadline(first: start, last: start, attempt: .distantPast), start.addingTimeInterval(5))
        XCTAssertEqual(OverleafLiveWorkspace.editDeadline(first: start, last: start.addingTimeInterval(30), attempt: .distantPast), start.addingTimeInterval(20))
        XCTAssertEqual(OverleafLiveWorkspace.editDeadline(first: start, last: start, attempt: start), start.addingTimeInterval(15))
    }
    func testHistoryOnlyRemoteCommitAdvancesBaseWithoutKeepingAStage() throws {
        try fixture { local, other, remote, connection in
            _ = try git(["commit", "--allow-empty", "-m", "History label"], other)
            _ = try git(["push"], other)
            let recovery = local.deletingLastPathComponent().appendingPathComponent("Recovery")
            let prepared = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            XCTAssertTrue(prepared.review.changes.isEmpty)
            XCTAssertEqual(try git(["rev-parse", "HEAD"], local), try git(["rev-parse", "main"], remote))
            XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.review.stage.path))
            let again = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            XCTAssertTrue(again.review.changes.isEmpty)
            XCTAssertEqual(again.review.fingerprint, "", "Unchanged checks do not hash every project file")
            XCTAssertFalse(FileManager.default.fileExists(atPath: again.review.stage.path))
        }
    }
    func testRejectedSourceIsNotAppliedTwiceAfterRestartOrMetadataFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let change = OverleafReviewSnapshot.Change(id: "test", documentID: "doc1", changeID: "change1", insertion: false, text: "restored", anchor: .init(file: "main.tex", source: "body", version: nil, offset: 0, length: 0), timestamp: nil)
        let first = try OverleafReviewRejection.prepare(change, root: root, source: "body")
        XCTAssertEqual(first.restored, "restoredbody")
        let retry = try OverleafReviewRejection.prepare(change, root: root, source: first.restored)
        XCTAssertEqual(retry.restored, first.restored)
        XCTAssertThrowsError(try OverleafReviewRejection.prepare(change, root: root, source: "newer local work"))
        let ranges = Data(#"[{"id":"doc1","ranges":{"changes":[{"id":"change1","op":{"p":8,"d":"restored"}}]}}]"#.utf8)
        XCTAssertTrue(try OverleafReviewRejection.needsResolution(change, ranges: ranges))
        XCTAssertFalse(try OverleafReviewRejection.needsResolution(change, ranges: Data("[]".utf8)))
        let changed = Data(#"[{"id":"doc1","ranges":{"changes":[{"id":"change1","op":{"p":8,"d":"different"}}]}}]"#.utf8)
        XCTAssertThrowsError(try OverleafReviewRejection.needsResolution(change, ranges: changed))
        try OverleafReviewRejection.finish(change, root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try OverleafReviewRejection.location(change, root: root).path))
    }
    private func git(_ args: [String], _ root: URL) throws -> String {
        try OverleafGit.run(["-c", "protocol.file.allow=always"] + args, at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func fixture(_ work: (URL, URL, URL, OverleafConnection) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let remote = folder.appendingPathComponent("remote.git"), local = folder.appendingPathComponent("local"), other = folder.appendingPathComponent("other")
        _ = try git(["init", "--bare", "--initial-branch=main", remote.path], folder)
        _ = try git(["clone", remote.path, local.path], folder)
        try "Alpha one\nBeta two\n".write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."], local); _ = try git(["commit", "-m", "Initial"], local); _ = try git(["push", "origin", "main"], local)
        _ = try git(["clone", remote.path, other.path], folder)
        let connection = OverleafConnection(id: UUID(), projectID: String(repeating: "a", count: 24), name: "Fixture", account: "Test", branch: "main")
        try work(local, other, remote, connection)
    }
    func testRemoteChangesMergeWithLocalWorkAndPreserveTypingDuringTransport() throws {
        try fixture { local, other, remote, connection in
            try "Alpha local\nBeta two\n".write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            try "Alpha one\nBeta remote\n".write(to: other.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            _ = try git(["add", "."], other); _ = try git(["commit", "-m", "Remote"], other); _ = try git(["push"], other)
            let prepared = try OverleafGitSync.prepare(connection, root: local, recovery: local.deletingLastPathComponent().appendingPathComponent("Recovery"), transport: remote.path)
            XCTAssertEqual(String(data: try XCTUnwrap(prepared.files["main.tex"]), encoding: .utf8), "Alpha local\nBeta remote\n")
            let current = ["main.tex": Data("Alpha local\nBeta two\nNew typing\n".utf8)]
            let merged = try OverleafGitSync.reconcile(base: prepared.review.localFiles, current: current, result: prepared.files)
            XCTAssertEqual(String(data: try XCTUnwrap(merged["main.tex"]), encoding: .utf8), "Alpha local\nBeta remote\nNew typing\n")
            try OverleafGitSync.publish(prepared)
            XCTAssertEqual(try git(["rev-parse", "main"], remote), prepared.head)
            XCTAssertEqual(try git(["rev-list", "--parents", "-n", "1", prepared.head], prepared.review.stage).split(separator: " ").count, 2, "Overleaf receives a single-parent commit")
            XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("main.tex"), encoding: .utf8), "Alpha local\nBeta two\n", "Transport never resets the live editor's files")
        }
    }
    func testRemoteChangeRacingPublishRejectsWithoutOverwritingEitherSide() throws {
        try fixture { local, other, remote, connection in
            try "My draft\n".write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            let prepared = try OverleafGitSync.prepare(connection, root: local, recovery: local.deletingLastPathComponent().appendingPathComponent("Recovery"), transport: remote.path)
            try "Their draft\n".write(to: other.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            _ = try git(["add", "."], other); _ = try git(["commit", "-m", "Racing edit"], other); _ = try git(["push"], other)
            let before = try git(["rev-parse", "main"], remote)
            XCTAssertThrowsError(try OverleafGitSync.publish(prepared))
            XCTAssertEqual(try git(["rev-parse", "main"], remote), before)
            XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.recovery.path))
            XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("main.tex"), encoding: .utf8), "My draft\n")
        }
    }
    func testOverlappingEditsRequireReviewAndKeepRecovery() throws {
        try fixture { local, other, remote, connection in
            try "My paragraph\n".write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            try "Their paragraph\n".write(to: other.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            _ = try git(["add", "."], other); _ = try git(["commit", "-m", "Remote edit"], other); _ = try git(["push"], other)
            let recovery = local.deletingLastPathComponent().appendingPathComponent("Recovery")
            XCTAssertThrowsError(try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: recovery.path).isEmpty)
            XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("main.tex"), encoding: .utf8), "My paragraph\n")
        }
    }
    func testIdenticalAndIndependentNewFilesAndDeletionConflicts() throws {
        let base = ["main.tex": Data("old".utf8), "image.png": Data([0, 1])]
        let current = base.merging(["notes.tex": Data("notes".utf8)]) { _, new in new }
        var result = base; result["main.tex"] = Data("new".utf8)
        let merged = try OverleafGitSync.reconcile(base: base, current: current, result: result)
        XCTAssertEqual(merged["notes.tex"], current["notes.tex"])
        XCTAssertEqual(merged["main.tex"], result["main.tex"])
        XCTAssertThrowsError(try OverleafGitSync.reconcile(base: base, current: ["main.tex": Data("edited".utf8)], result: [:]))
        XCTAssertThrowsError(try OverleafGitSync.reconcile(base: base, current: ["image.png": Data([4, 5])], result: ["image.png": Data([6, 7])]))
    }
    @MainActor func testOnDeviceChoiceAndOfflineStatusAreIndependent() async {
        let suite = "remile.git-test." + UUID().uuidString
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        let id = UUID()
        XCTAssertTrue(OverleafSyncPreference.live(id, store: store))
        OverleafSyncPreference.choose(false, for: id, store: store)
        XCTAssertFalse(OverleafSyncPreference.live(id, store: store))
        let workspace = OverleafLiveWorkspace()
        await workspace.stop()
        XCTAssertFalse(workspace.enabled)
        XCTAssertEqual(workspace.automationStatus["transport"] as? String, "git")
        XCTAssertFalse(workspace.automationStatus["confirmed"] as? Bool ?? true)
    }
    @MainActor func testPrivateWebEndpointsFailClosed() async {
        do {
            _ = try await OverleafWebClient.request("/user/projects", profile: UUID())
            XCTFail("A Git-only integration must not fetch browser endpoints")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Git")) }
    }
    @MainActor func testOnlyReviewReadPathsAreAllowed() {
        let id = String(repeating: "a", count: 24)
        XCTAssertTrue(OverleafWebClient.reviewPath("/project/" + id + "/threads"))
        XCTAssertTrue(OverleafWebClient.reviewPath("/project/" + id + "/ranges"))
        XCTAssertTrue(OverleafWebClient.reviewPath("/project/" + id + "/changes/users"))
        XCTAssertTrue(OverleafWebClient.reviewPath("/Project/" + id + "/doc/" + id + "/download", document: true))
        for path in ["/user/projects", "/tag", "/project/" + id + "/compile", "/socket.io/1/", "/project/" + id + "/threads?next=1"] {
            XCTAssertFalse(OverleafWebClient.reviewPath(path))
        }
    }
    @MainActor func testOnlineWorkspaceReceivesAndPublishesWithoutReloadingTheEditor() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let remote = folder.appendingPathComponent("remote.git"), local = folder.appendingPathComponent("local"), other = folder.appendingPathComponent("other")
        _ = try git(["init", "--bare", "--initial-branch=main", remote.path], folder)
        _ = try git(["clone", remote.path, local.path], folder)
        let source = "\\documentclass{article}\n\\begin{document}\nFirst\n\\end{document}\n"
        try source.write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."], local); _ = try git(["commit", "-m", "Initial"], local); _ = try git(["push", "origin", "main"], local)
        _ = try git(["clone", remote.path, other.path], folder)
        let project = try TeXProject(local, historyEnabled: false)
        XCTAssertEqual(project.files, ["main.tex"])
        let identity = project.identity
        let library = OverleafLibrary(directory: folder.appendingPathComponent("Library"))
        let connection = OverleafConnection(id: UUID(), projectID: String(repeating: "a", count: 24), name: "Fixture", account: "Test", branch: "main")
        let workspace = OverleafLiveWorkspace(transport: remote.path)
        await workspace.start(project: project, library: library, connection: connection)
        await workspace.retry()
        XCTAssertTrue(workspace.connected, workspace.issue ?? "Not connected")
        project.buffers["main.tex"] = source.replacingOccurrences(of: "First", with: "Local")
        workspace.edited(); await workspace.retry()
        XCTAssertTrue(workspace.connected, workspace.issue ?? "Not connected")
        XCTAssertEqual(try git(["show", "main:main.tex"], remote), project.buffers["main.tex"]?.trimmingCharacters(in: .whitespacesAndNewlines))
        _ = try git(["pull", "--ff-only"], other)
        let updated = project.buffers["main.tex"]!.replacingOccurrences(of: "Local", with: "Remote")
        try updated.write(to: other.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."], other); _ = try git(["commit", "-m", "Remote"], other); _ = try git(["push"], other)
        project.compiling = true
        await workspace.retry()
        project.compiling = false
        XCTAssertEqual(project.buffers["main.tex"], updated)
        XCTAssertEqual(project.identity, identity)
        XCTAssertEqual(workspace.pendingDocumentCount, 0)
        await workspace.stop()
        project.buffers["main.tex"] = updated + "% Offline draft\n"
        await workspace.flush()
        XCTAssertEqual(try git(["show", "main:main.tex"], remote), updated.trimmingCharacters(in: .whitespacesAndNewlines))
    }

}
