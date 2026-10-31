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
    @MainActor func testCollaborationWindowAndForegroundChecksStayBounded() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(OverleafLiveWorkspace.remoteDelay(unchangedChecks: 9, activeUntil: now.addingTimeInterval(1), now: now), 15)
        XCTAssertEqual(OverleafLiveWorkspace.remoteDelay(unchangedChecks: 1, activeUntil: now, now: now), 60)
        XCTAssertEqual(OverleafLiveWorkspace.remoteDelay(unchangedChecks: 9, activeUntil: now, now: now), 300)
        XCTAssertEqual(OverleafLiveWorkspace.foregroundDeadline(now: now, attempt: now.addingTimeInterval(-2)), now.addingTimeInterval(13))
        XCTAssertEqual(OverleafLiveWorkspace.foregroundDeadline(now: now, attempt: now.addingTimeInterval(-30)), now)
    }
    func testConcurrentPushRebuildsAgainstNewRemoteAndKeepsLaterLocalWriting() throws {
        try fixture { local, other, remote, connection in
            try "Alpha local\nBeta two\n".write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            let recovery = local.deletingLastPathComponent().appendingPathComponent("Recovery")
            let pending = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            try "Alpha one\nBeta remote\n".write(to: other.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            _ = try git(["add", "."], other); _ = try git(["commit", "-m", "Concurrent remote edit"], other); _ = try git(["push"], other)
            let remoteBefore = try git(["rev-parse", "main"], remote)
            XCTAssertThrowsError(try OverleafGitSync.publish(pending)) { XCTAssertTrue($0 is OverleafGitSync.RemoteAdvanced) }
            XCTAssertEqual(try git(["rev-parse", "main"], remote), remoteBefore)
            let localNow = "Alpha local\nBeta two\nLater local writing\n"
            try localNow.write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            let outcome = try OverleafGitSync.synchronise(connection, root: local, recovery: recovery, transport: remote.path)
            XCTAssertTrue(outcome.caughtUp)
            let expected = "Alpha local\nBeta remote\nLater local writing\n"
            XCTAssertEqual(outcome.prepared.files["main.tex"], Data(expected.utf8))
            XCTAssertEqual(try git(["show", "main:main.tex"], remote), expected.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("main.tex"), encoding: .utf8), localNow, "Preparation never replaces the active editor files")
            XCTAssertEqual(try git(["rev-parse", "main^"], remote), remoteBefore, "Normal linear push retains the collaborator's commit")
            try OverleafSyncRecovery.finish(outcome.prepared)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: recovery.path).isEmpty)
        }
    }
    func testRewrittenRemoteDoesNotSilentlyRepublishAnInstalledCommit() throws {
        try fixture { local, other, remote, connection in
            try "Alpha local\nBeta two\n".write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            let recovery = local.deletingLastPathComponent().appendingPathComponent("Recovery")
            let pending = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            XCTAssertTrue(try OverleafGitSync.publish(pending))
            _ = try git(["reset", "--mixed", pending.head], local)
            try "Alpha one\nBeta rewritten\n".write(to: other.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            _ = try git(["add", "."], other); _ = try git(["commit", "-m", "Rewritten temporary test history"], other)
            _ = try git(["push", "--force"], other)
            let remoteBefore = try git(["rev-parse", "main"], remote)
            XCTAssertThrowsError(try OverleafGitSync.synchronise(connection, root: local, recovery: recovery, transport: remote.path)) { XCTAssertTrue($0 is OverleafGitSync.ReviewRequired) }
            XCTAssertEqual(try git(["rev-parse", "main"], remote), remoteBefore)
            XCTAssertTrue(FileManager.default.fileExists(atPath: pending.recovery.path))
            _ = try git(["update-ref", "refs/heads/main", pending.review.remoteHead], remote)
            XCTAssertThrowsError(try OverleafGitSync.synchronise(connection, root: local, recovery: recovery, transport: remote.path)) { XCTAssertTrue($0 is OverleafGitSync.ReviewRequired) }
            XCTAssertEqual(try git(["rev-parse", "main"], remote), pending.review.remoteHead, "An exact server rollback must also remain a review")
        }
    }
    func testConcurrentOverlappingEditStillPausesWithoutOverwritingEitherSide() throws {
        try fixture { local, other, remote, connection in
            let localText = "Alpha local\nBeta two\n"
            try localText.write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            let recovery = local.deletingLastPathComponent().appendingPathComponent("Recovery")
            _ = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            try "Alpha remote\nBeta two\n".write(to: other.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            _ = try git(["add", "."], other); _ = try git(["commit", "-m", "Overlapping edit"], other); _ = try git(["push"], other)
            let remoteBefore = try git(["rev-parse", "main"], remote)
            XCTAssertThrowsError(try OverleafGitSync.synchronise(connection, root: local, recovery: recovery, transport: remote.path)) { XCTAssertTrue($0 is OverleafGitSync.ReviewRequired) }
            XCTAssertEqual(try git(["rev-parse", "main"], remote), remoteBefore)
            XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("main.tex"), encoding: .utf8), localText)
        }
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
    func testAutomaticPreparationSkipsDisplayCopiesWithoutChangingManualReview() throws {
        try fixture { local, other, remote, connection in
            try "Remote body\n".write(to: other.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            _ = try git(["add", "."], other); _ = try git(["commit", "-m", "Remote edit"], other); _ = try git(["push"], other)
            let recovery = local.deletingLastPathComponent().appendingPathComponent("Recovery")
            let automatic = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            XCTAssertTrue(automatic.review.changes.allSatisfy { $0.local.isEmpty && $0.remote.isEmpty && $0.result.isEmpty })
            XCTAssertEqual(automatic.files["main.tex"], Data("Remote body\n".utf8))
            let manual = try OverleafGit.prepare(connection, root: local, reviewRoot: recovery, transport: remote.path)
            let change = try XCTUnwrap(manual.changes.first)
            XCTAssertEqual(change.local, "Alpha one\nBeta two\n")
            XCTAssertEqual(change.remote, "Remote body\n")
            XCTAssertEqual(change.result, "Remote body\n")
            XCTAssertEqual(manual.changes.map(\.path), automatic.review.changes.map(\.path))
            XCTAssertEqual(manual.fingerprint, automatic.review.fingerprint)
        }
    }
    func testGitCommandHonoursCancellationBeforeStarting() async {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try OverleafGit.run(["--version"], at: FileManager.default.temporaryDirectory)
        }
        do { _ = try await task.value; XCTFail("Cancelled Git work must not start") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testMultiFilePreparationBenchmark() throws {
        guard ProcessInfo.processInfo.environment["REMILE_GIT_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in local Git benchmark") }
        try fixture { local, other, remote, connection in
            let clock = ContinuousClock()
            let start = clock.now
            for _ in 0..<20 { _ = try git(["rev-parse", "HEAD"], local) }
            print("GIT_BENCH 20-local-commands \(start.duration(to: clock.now))")
            for index in 0..<20 { try "Remote document \(index)\n".write(to: other.appendingPathComponent("chapter\(index).tex"), atomically: true, encoding: .utf8) }
            _ = try git(["add", "."], other); _ = try git(["commit", "-m", "Twenty documents"], other); _ = try git(["push"], other)
            let prepareStart = clock.now
            let prepared = try OverleafGitSync.prepare(connection, root: local, recovery: local.deletingLastPathComponent().appendingPathComponent("Recovery"), transport: remote.path)
            print("GIT_BENCH 20-file-prepare \(prepareStart.duration(to: clock.now))")
            XCTAssertEqual(prepared.review.changes.count, 20)
            XCTAssertEqual(prepared.files.count, 21)
            for index in 0..<20 { XCTAssertEqual(prepared.files["chapter\(index).tex"], Data("Remote document \(index)\n".utf8)) }
        }
    }
    func testRecoverySharesImmutableAttachmentsWithCopyOnWrite() throws {
        try fixture { local, _, remote, connection in
            let bytes = Data(repeating: 73, count: 1024 * 1024)
            try bytes.write(to: local.appendingPathComponent("image.bin"))
            try bytes.write(to: local.appendingPathComponent("same-image.bin"))
            _ = try git(["add", "."], local); _ = try git(["commit", "-m", "Attachments"], local); _ = try git(["push"], local)
            try "Changed source\n".write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            let recovery = local.deletingLastPathComponent().appendingPathComponent("Recovery")
            _ = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            let resumed = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            let base = try XCTUnwrap(resumed.review.localFiles["image.bin"])
            let result = try XCTUnwrap(resumed.files["image.bin"])
            let duplicate = try XCTUnwrap(resumed.files["same-image.bin"])
            base.withUnsafeBytes { a in
                result.withUnsafeBytes { b in
                    duplicate.withUnsafeBytes { c in
                        XCTAssertEqual(a.baseAddress, b.baseAddress, "Unchanged attachments share one allocation")
                        XCTAssertEqual(a.baseAddress, c.baseAddress, "Repeated content at a different path is read once")
                    }
                }
            }
            XCTAssertEqual(result, bytes)
            XCTAssertEqual(resumed.files["main.tex"], Data("Changed source\n".utf8))
            var edited = result; edited[0] = 12
            XCTAssertEqual(base[0], 73, "Copy-on-write must isolate later modifications")
            XCTAssertEqual(resumed.files["same-image.bin"]?[0], 73)
        }
    }
    func testRecoveryReuseBenchmark() throws {
        guard ProcessInfo.processInfo.environment["REMILE_GIT_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in recovery benchmark") }
        try fixture { local, _, remote, connection in
            let bytes = Data(repeating: 73, count: 1024 * 1024)
            for index in 0..<24 { try bytes.write(to: local.appendingPathComponent("asset\(index).bin")) }
            _ = try git(["add", "."], local); _ = try git(["commit", "-m", "Repeated attachments"], local); _ = try git(["push"], local)
            try "Local edit\n".write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            let recovery = local.deletingLastPathComponent().appendingPathComponent("Recovery")
            _ = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            let clock = ContinuousClock(), start = ContinuousClock.now
            let resumed = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            print("GIT_BENCH resume-24-attachments \(start.duration(to: clock.now))")
            XCTAssertTrue(resumed.resumed)
            XCTAssertEqual(resumed.files.count, 25)
            for index in 0..<24 { XCTAssertEqual(resumed.files["asset\(index).bin"], bytes) }
        }
    }
    func testInterruptedPreparationResumesTheSameCopyAndKeepsNewTyping() throws {
        try fixture { local, other, remote, connection in
            try "Alpha local\nBeta two\n".write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            try "Alpha one\nBeta remote\n".write(to: other.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            _ = try git(["add", "."], other); _ = try git(["commit", "-m", "Remote"], other); _ = try git(["push"], other)
            let recovery = local.deletingLastPathComponent().appendingPathComponent("Recovery")
            let first = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            let current = "Alpha local\nBeta two\nTyped after interruption\n"
            try current.write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            for _ in 0..<3 {
                let resumed = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
                XCTAssertTrue(resumed.resumed); XCTAssertEqual(resumed.head, first.head); XCTAssertEqual(resumed.recovery, first.recovery)
                let merged = try OverleafGitSync.reconcile(base: resumed.review.localFiles, current: ["main.tex": Data(current.utf8)], result: resumed.files)
                XCTAssertEqual(merged["main.tex"], Data("Alpha local\nBeta remote\nTyped after interruption\n".utf8))
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: recovery.path).count, 2, "One stage and one small receipt")
            XCTAssertTrue(try OverleafGitSync.publish(first))
        }
    }
    func testLostPushResponseAndInterruptedInstallDoNotPublishTwice() throws {
        try fixture { local, _, remote, connection in
            try "Only local writing\n".write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            let recovery = local.deletingLastPathComponent().appendingPathComponent("Recovery")
            let first = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            XCTAssertTrue(try OverleafGitSync.publish(first))
            let remoteHead = try git(["rev-parse", "main"], remote)
            let resumed = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            XCTAssertTrue(resumed.resumed)
            XCTAssertTrue(try OverleafGitSync.publish(resumed))
            XCTAssertEqual(try git(["rev-parse", "main"], remote), remoteHead)
            try XCTUnwrap(resumed.files["main.tex"]).write(to: local.appendingPathComponent("main.tex"))
            _ = try git(["reset", "--mixed", resumed.head], local)
            let afterInstall = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            XCTAssertTrue(afterInstall.resumed)
            XCTAssertTrue(try OverleafGitSync.publish(afterInstall))
            try OverleafSyncRecovery.finish(afterInstall)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: recovery.path).isEmpty)
            XCTAssertFalse(try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path).resumed)
        }
    }
    func testInterruptedSyncDoesNotOverwriteAChangedRemote() throws {
        try fixture { local, other, remote, connection in
            try "Local work\n".write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            let recovery = local.deletingLastPathComponent().appendingPathComponent("Recovery")
            let first = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            try "New remote work\n".write(to: other.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            _ = try git(["add", "."], other); _ = try git(["commit", "-m", "Changed while offline"], other); _ = try git(["push"], other)
            let remoteHead = try git(["rev-parse", "main"], remote)
            let resumed = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            XCTAssertThrowsError(try OverleafGitSync.publish(resumed))
            XCTAssertEqual(try git(["rev-parse", "main"], remote), remoteHead)
            XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("main.tex"), encoding: .utf8), "Local work\n")
            XCTAssertTrue(FileManager.default.fileExists(atPath: first.recovery.path))
        }
    }
    func testCompletedSyncsKeepOnlyThreeRecoveryReferences() throws {
        try fixture { local, _, remote, connection in
            _ = try git(["update-ref", "refs/heads/keep-this", "HEAD"], local)
            let legacy = "refs/remile/git-recovery/" + UUID().uuidString.lowercased()
            _ = try git(["update-ref", legacy, "HEAD"], local)
            let recovery = local.deletingLastPathComponent().appendingPathComponent("Recovery")
            for revision in 0..<6 {
                try "Revision \(revision)\n".write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
                let pending = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
                XCTAssertTrue(try OverleafGitSync.publish(pending))
                _ = try git(["reset", "--mixed", pending.head], local)
                try OverleafSyncRecovery.finish(pending)
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: recovery.path).isEmpty)
            }
            let refs = try git(["for-each-ref", "--format=%(refname)", "refs/remile/git-recovery/"], local).split(separator: "\n")
            XCTAssertEqual(refs.count, 4, "Three managed snapshots plus the unresolved legacy reference")
            XCTAssertFalse(try git(["rev-parse", legacy], local).isEmpty)
            XCTAssertFalse(try git(["rev-parse", "refs/heads/keep-this"], local).isEmpty)
        }
    }
    func testRestartAcknowledgesAPushWhenTheRemoteHasAdvancedAgain() throws {
        try fixture { local, other, remote, connection in
            try "Local writing\n".write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            let recovery = local.deletingLastPathComponent().appendingPathComponent("Recovery")
            let first = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            XCTAssertTrue(try OverleafGitSync.publish(first))
            _ = try git(["pull", "--ff-only"], other)
            _ = try git(["commit", "--allow-empty", "-m", "Remote advanced"], other); _ = try git(["push"], other)
            let remoteHead = try git(["rev-parse", "main"], remote)
            let resumed = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            XCTAssertFalse(try OverleafGitSync.publish(resumed))
            XCTAssertEqual(try git(["rev-parse", "main"], remote), remoteHead)
        }
    }
    func testRecoveryBudgetAndDamagedReceiptPreservePendingFiles() throws {
        try fixture { local, _, remote, connection in
            let recovery = local.deletingLastPathComponent().appendingPathComponent("Recovery")
            try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
            let pending = recovery.appendingPathComponent("existing-pending")
            FileManager.default.createFile(atPath: pending.path, contents: nil)
            let handle = try FileHandle(forWritingTo: pending)
            try handle.truncate(atOffset: UInt64(OverleafSyncRecovery.byteLimit)); try handle.close()
            XCTAssertThrowsError(try OverleafSyncRecovery.checkCapacity(root: local, recovery: recovery))
            XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
            // Remove only this synthetic quota fixture so the damaged-receipt case can prepare normally.
            try FileManager.default.removeItem(at: pending)
            try "Saved locally\n".write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            let prepared = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            let receipt = recovery.appendingPathComponent(connection.id.uuidString.lowercased() + ".json")
            try Data("unreadable".utf8).write(to: receipt)
            XCTAssertThrowsError(try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.recovery.path))
            XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("main.tex"), encoding: .utf8), "Saved locally\n")
        }
    }
    func testRepeatedInterruptionsBeforeReceiptDoNotAccumulateSnapshotReferences() throws {
        try fixture { local, _, remote, connection in
            let recovery = local.deletingLastPathComponent().appendingPathComponent("Recovery")
            for revision in 0..<5 {
                try "Unfinished revision \(revision)\n".write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
                _ = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
                // Simulate the earlier interruption point before a durable receipt had been written.
                try FileManager.default.removeItem(at: recovery.appendingPathComponent(connection.id.uuidString.lowercased() + ".json"))
            }
            let refs = try git(["for-each-ref", "--format=%(refname)", "refs/remile/"], local).split(separator: "\n")
            XCTAssertEqual(refs.map(String.init), ["refs/remile/git-pending"])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: recovery.path).count, 1)
        }
    }
    @MainActor func testLiveInstallRejectsTypingAfterValidationAndNoOpKeepsFileRevision() throws {
        try fixture { local, _, _, _ in
            let project = try TeXProject(local, historyEnabled: false)
            let current = try OverleafLiveFiles.scan(local, buffers: project.buffers)
            var incoming = current; incoming["main.tex"] = Data("Remote writing\n".utf8)
            let plan = try TeXProject.prepareLiveInstall(root: local, buffers: project.buffers, editRevision: project.editRevision,
                fileRevision: project.fileRevision, base: current, result: incoming, head: try git(["rev-parse", "HEAD"], local))
            project.buffers["main.tex"] = "Typing after validation\n"
            XCTAssertThrowsError(try project.installLiveFiles(plan))
            XCTAssertEqual(project.buffers["main.tex"], "Typing after validation\n")
            XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("main.tex"), encoding: .utf8), "Alpha one\nBeta two\n")
            let latest = try OverleafLiveFiles.scan(local, buffers: project.buffers)
            let noOp = try TeXProject.prepareLiveInstall(root: local, buffers: project.buffers, editRevision: project.editRevision,
                fileRevision: project.fileRevision, base: latest, result: latest, head: try git(["rev-parse", "HEAD"], local))
            let revision = project.fileRevision
            try project.installLiveFiles(noOp)
            XCTAssertEqual(project.fileRevision, revision)
            XCTAssertEqual(project.buffers["main.tex"], "Typing after validation\n")
        }
    }
    @MainActor func testLiveInstallRejectsExternalAttachmentChangesAfterValidation() throws {
        try fixture { local, _, _, _ in
            let file = local.appendingPathComponent("image.bin")
            try Data([1, 2]).write(to: file)
            let project = try TeXProject(local, historyEnabled: false)
            let current = try OverleafLiveFiles.scan(local, buffers: project.buffers)
            var incoming = current; incoming["image.bin"] = Data([3, 4])
            let plan = try TeXProject.prepareLiveInstall(root: local, buffers: project.buffers, editRevision: project.editRevision,
                fileRevision: project.fileRevision, base: current, result: incoming, head: try git(["rev-parse", "HEAD"], local))
            try Data([5, 6]).write(to: file)
            XCTAssertThrowsError(try project.installLiveFiles(plan))
            XCTAssertEqual(try Data(contentsOf: file), Data([5, 6]))
        }
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
            _ = try await OverleafWebClient.request("/user/settings", profile: UUID())
            XCTFail("The catalogue exception must not allow unrelated browser endpoints")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Source sync uses Git")) }
    }
    @MainActor func testCatalogueReadsListAndOptionalTagsOnce() async throws {
        let profile = UUID()
        var calls: [String] = []
        let id = String(repeating: "a", count: 24)
        let payload = Data("{\"projects\":[{\"_id\":\"\(id)\",\"name\":\"Sample\"}]}".utf8)
        let projects = try await OverleafWebClient.projects(profile) { path, receivedProfile in
            calls.append(path)
            XCTAssertEqual(receivedProfile, profile)
            if path == "/tag" {
                return Data("[{\"_id\":\"tag-1\",\"name\":\"Research\",\"color\":\"#123456\",\"project_ids\":[\"\(id)\"]}]".utf8)
            }
            return payload
        }
        XCTAssertEqual(calls, ["/user/projects", "/tag"])
        XCTAssertEqual(projects.map(\.name), ["Sample"])
        XCTAssertEqual(projects[0].tags.first?.color, "#123456")
    }
    @MainActor func testTagFailureDoesNotHideProjects() async throws {
        let id = String(repeating: "b", count: 24)
        var calls: [String] = []
        let projects = try await OverleafWebClient.projects(UUID()) { path, _ in
            calls.append(path)
            if path == "/tag" { throw OverleafWebClient.Failure.unavailable }
            return Data("{\"projects\":[{\"_id\":\"\(id)\",\"name\":\"Still available\"}]}".utf8)
        }
        XCTAssertEqual(projects.map(\.name), ["Still available"])
        XCTAssertFalse(projects[0].tagsLoaded)
        XCTAssertEqual(calls, ["/user/projects", "/tag"])
    }
    func testProjectTagGroupsKeepEveryMembershipAndUntaggedLast() {
        let alpha = OverleafWebClient.Tag(id: "alpha", name: "Alpha", color: "#123456")
        let beta = OverleafWebClient.Tag(id: "beta", name: "Beta", color: nil)
        let shared = OverleafWebClient.Project(id: "shared", name: "Shared", tags: [beta, alpha])
        let plain = OverleafWebClient.Project(id: "plain", name: "Plain")
        let groups = OverleafProjects.grouped([plain, shared])
        XCTAssertEqual(groups.map(\.id), [.tag("alpha"), .tag("beta"), .untagged])
        XCTAssertEqual(groups.map { $0.projects.map(\.id) }, [["shared"], ["shared"], ["plain"]])
        XCTAssertTrue(OverleafProjects.grouped([]).isEmpty)
    }
    func testCatalogueReadExceptionIsExact() {
        XCTAssertTrue(OverleafWebClient.allowedReadPath("/user/projects"))
        XCTAssertTrue(OverleafWebClient.allowedReadPath("/tag"))
        XCTAssertFalse(OverleafWebClient.allowedReadPath("/user/projects", document: true))
        for path in ["/tag?all=true", "/user/settings", "/user/projects?all=true", "/user/projects/", "/user/projects/../settings", "/socket.io/1/"] {
            XCTAssertFalse(OverleafWebClient.allowedReadPath(path))
        }
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
        try (source + "% Remote collaborator\n").write(to: other.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."], other); _ = try git(["commit", "-m", "Independent simultaneous edit"], other); _ = try git(["push"], other)
        workspace.edited(); await workspace.retry()
        XCTAssertTrue(workspace.connected, workspace.issue ?? "Not connected")
        XCTAssertFalse(workspace.requiresGitReview)
        XCTAssertEqual(project.buffers["main.tex"], source.replacingOccurrences(of: "First", with: "Local") + "% Remote collaborator\n")
        let checks = workspace.automationStatus["gitChecks"] as? Int
        workspace.setVisible(false); workspace.setVisible(true); workspace.foregrounded()
        await workspace.flush()
        XCTAssertEqual(workspace.automationStatus["gitChecks"] as? Int, checks, "Quick window changes must not trigger repeated fetches")
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
