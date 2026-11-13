import Foundation
import XCTest
@testable import Remile

final class OverleafGitSyncTests: XCTestCase {
    @MainActor func testSyncScheduleBacksOffAndCoalescesEdits() {
        XCTAssertEqual((0...6).map { OverleafOnlineWorkspace.idleDelay(unchangedChecks: $0) }, [30, 30, 60, 60, 60, 60, 60])
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(OverleafOnlineWorkspace.editDeadline(first: start, last: start, attempt: .distantPast), start.addingTimeInterval(5))
        XCTAssertEqual(OverleafOnlineWorkspace.editDeadline(first: start, last: start.addingTimeInterval(30), attempt: .distantPast), start.addingTimeInterval(20))
        XCTAssertEqual(OverleafOnlineWorkspace.editDeadline(first: start, last: start, attempt: start), start.addingTimeInterval(15))
    }
    @MainActor func testCollaborationWindowAndForegroundChecksStayBounded() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(OverleafOnlineWorkspace.remoteDelay(unchangedChecks: 9, activeUntil: now.addingTimeInterval(1), now: now), 15)
        XCTAssertEqual(OverleafOnlineWorkspace.remoteDelay(unchangedChecks: 1, activeUntil: now, now: now), 30)
        XCTAssertEqual(OverleafOnlineWorkspace.remoteDelay(unchangedChecks: 9, activeUntil: now, now: now), 60)
        XCTAssertEqual(OverleafOnlineWorkspace.foregroundDeadline(now: now, attempt: now.addingTimeInterval(-2)), now.addingTimeInterval(13))
        XCTAssertEqual(OverleafOnlineWorkspace.foregroundDeadline(now: now, attempt: now.addingTimeInterval(-30)), now)
    }
    func testConfirmedSyncDoesNotMoveAChangedLocalBranch() throws {
        try fixture { local, _, remote, connection in
            let file = local.appendingPathComponent("main.tex")
            try "Prepared writing\n".write(to: file, atomically: true, encoding: .utf8)
            let recovery = local.deletingLastPathComponent().appendingPathComponent("Recovery")
            var transfers: [OverleafGit.Transfer] = []
            let outcome = try OverleafGitSync.synchronise(connection, root: local, recovery: recovery, transport: remote.path) { transfers.append($0) }
            XCTAssertEqual(transfers.map(\.phase.rawValue), ["fetch", "push", "confirm"])
            XCTAssertTrue(transfers.allSatisfy { $0.succeeded && $0.milliseconds >= 0 })
            XCTAssertEqual(try git(["rev-parse", "main"], remote), outcome.prepared.head)

            try "New local Git commit\n".write(to: file, atomically: true, encoding: .utf8)
            _ = try git(["add", "main.tex"], local)
            _ = try git(["commit", "-m", "External commit while confirming"], local)
            let localHead = try git(["rev-parse", "HEAD"], local)
            XCTAssertThrowsError(try OverleafGitSync.advanceLocalBase(outcome.prepared)) { XCTAssertTrue($0 is OverleafGitSync.ReviewRequired) }
            XCTAssertEqual(try git(["rev-parse", "HEAD"], local), localHead)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "New local Git commit\n")
            XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.prepared.recovery.path))
        }
    }

    func testTransportFailureReportsHTTPStatusWithoutServerOutput() {
        let failure = OverleafGit.transportFailure("fatal: unable to access 'https://private.example/': the requested url returned error: 403")
        XCTAssertEqual(failure.httpStatus, 403)
        XCTAssertEqual(failure.retryAfter, 120)
        XCTAssertFalse(failure.localizedDescription.contains("private.example"))
        XCTAssertEqual(OverleafGit.transportFailure("the requested url returned error: 429").retryAfter, 300)
        XCTAssertNil(OverleafGit.transportFailure("could not resolve host").httpStatus)
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
            XCTAssertTrue(FileManager.default.fileExists(atPath: pending.recovery.path))
            XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("main.tex"), encoding: .utf8), "Alpha local\nBeta two\n")
            let localNow = "Alpha local\nBeta two\nLater local writing\n"
            try localNow.write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            let outcome = try OverleafGitSync.synchronise(connection, root: local, recovery: recovery, transport: remote.path)
            let expected = "Alpha local\nBeta remote\nLater local writing\n"
            XCTAssertEqual(outcome.prepared.files["main.tex"], Data(expected.utf8))
            XCTAssertEqual(try git(["show", "main:main.tex"], remote), expected.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("main.tex"), encoding: .utf8), localNow, "Preparation never replaces the active editor files")
            XCTAssertEqual(try git(["rev-parse", "main^"], remote), remoteBefore, "Normal linear push retains the collaborator's commit")
            try OverleafSyncRecovery.finish(outcome.prepared)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: recovery.path).isEmpty)
        }
    }
    func testSameParagraphConcurrentEditsConvergeThroughGit() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["REMILE_OVERLEAF_COLLABORATION_CHECKS"] == "1", "Optional collaboration scenario")
        try fixture { local, other, remote, connection in
            let base = "The alpha model uses stable chemistry and gamma transport.\n"
            try base.write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            _ = try git(["add", "."], local); _ = try git(["commit", "-m", "Paragraph fixture"], local); _ = try git(["push"], local)
            _ = try git(["pull", "--ff-only"], other)
            let writing = base.replacingOccurrences(of: "alpha", with: "ALPHA").replacingOccurrences(of: "gamma", with: "GAMMA")
            try writing.write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            try base.replacingOccurrences(of: "chemistry", with: "CHEMISTRY").write(to: other.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            _ = try git(["add", "."], other); _ = try git(["commit", "-m", "Collaborator paragraph edit"], other); _ = try git(["push"], other)
            let outcome = try OverleafGitSync.synchronise(connection, root: local, recovery: local.deletingLastPathComponent().appendingPathComponent("Recovery"), transport: remote.path)
            let expected = writing.replacingOccurrences(of: "chemistry", with: "CHEMISTRY")
            XCTAssertEqual(outcome.prepared.files["main.tex"], Data(expected.utf8))
            XCTAssertEqual(try git(["show", "main:main.tex"], remote), expected.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("main.tex"), encoding: .utf8), writing)
            try OverleafSyncRecovery.finish(outcome.prepared)
        }
    }
    func testContinuedTypingAndNewLastLineConvergeThroughGit() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["REMILE_OVERLEAF_COLLABORATION_CHECKS"] == "1", "Optional collaboration scenario")
        try fixture { local, other, remote, connection in
            let base = "A document\nI am typin"
            try base.write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            _ = try git(["add", "."], local); _ = try git(["commit", "-m", "Unfinished last line"], local); _ = try git(["push"], local)
            _ = try git(["pull", "--ff-only"], other)
            let writing = base + "\n% separate note\n"
            try writing.write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            let remoteText = base + "g another sentence.\n\n"
            try remoteText.write(to: other.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            _ = try git(["add", "."], other); _ = try git(["commit", "-m", "Continue last line"], other); _ = try git(["push"], other)
            let outcome = try OverleafGitSync.synchronise(connection, root: local, recovery: local.deletingLastPathComponent().appendingPathComponent("Recovery"), transport: remote.path)
            let expected = remoteText + "\n% separate note\n"
            XCTAssertEqual(outcome.prepared.files["main.tex"], Data(expected.utf8))
            XCTAssertEqual(try git(["show", "main:main.tex"], remote), expected.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("main.tex"), encoding: .utf8), writing)
            try OverleafSyncRecovery.finish(outcome.prepared)
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
    func testRetrySkipsUnpublishedSnapshotWhenLocalChangesWereUndone() throws {
        try fixture { local, _, remote, connection in
            let recovery = local.deletingLastPathComponent().appendingPathComponent("Recovery")
            let folder = local.appendingPathComponent("Figures")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: folder.appendingPathComponent("temporary.pdf"))
            let first = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            try FileManager.default.removeItem(at: folder)

            let retry = try OverleafGitSync.synchronise(connection, root: local, recovery: recovery, transport: remote.path)
            XCTAssertFalse(retry.prepared.resumed)
            XCTAssertEqual(try git(["rev-parse", "main"], remote), first.originalHead)
            XCTAssertEqual(try git(["ls-tree", "-r", "--name-only", "main"], remote), "main.tex")
        }
    }

    func testRetryRecognisesEquivalentPublicationAndKeepsLaterLocalUndo() throws {
        try fixture { local, other, remote, connection in
            let recovery = local.deletingLastPathComponent().appendingPathComponent("Recovery")
            let folder = local.appendingPathComponent("Figures/Draft")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: folder.appendingPathComponent("temporary.pdf"))
            let first = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            try FileManager.default.removeItem(at: local.appendingPathComponent("Figures"))

            let otherFolder = other.appendingPathComponent("Figures/Draft")
            try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: otherFolder.appendingPathComponent("temporary.pdf"))
            _ = try git(["add", "Figures"], other)
            _ = try git(["commit", "-m", "Update on Overleaf."], other)
            XCTAssertNotEqual(try git(["rev-parse", "HEAD"], other), first.head)
            XCTAssertEqual(try git(["rev-parse", "HEAD^{tree}"], other), try git(["rev-parse", first.head + "^{tree}"], first.recovery))
            try "Collaborator chapter\n".write(to: other.appendingPathComponent("chapter.tex"), atomically: true, encoding: .utf8)
            _ = try git(["add", "chapter.tex"], other)
            _ = try git(["commit", "-m", "Collaborator chapter"], other)
            _ = try git(["push"], other)
            let remoteHead = try git(["rev-parse", "main"], remote)

            let retry = try OverleafGitSync.synchronise(connection, root: local, recovery: recovery, transport: remote.path)
            XCTAssertTrue(retry.prepared.resumed)
            XCTAssertEqual(retry.prepared.head, remoteHead)
            let merged = try OverleafGitSync.reconcile(base: retry.prepared.review.localFiles,
                                                       current: OverleafSourceFiles.scan(local), result: retry.prepared.files)
            XCTAssertNil(merged["Figures/Draft/temporary.pdf"])
            let chapterBytes = try XCTUnwrap(merged["chapter.tex"])
            XCTAssertEqual(chapterBytes, Data("Collaborator chapter\n".utf8))

            try chapterBytes.write(to: local.appendingPathComponent("chapter.tex"))
            _ = try git(["reset", "--mixed", retry.prepared.head], local)
            try OverleafSyncRecovery.finish(retry.prepared)
            _ = try OverleafGitSync.synchronise(connection, root: local, recovery: recovery, transport: remote.path)
            XCTAssertEqual(try git(["ls-tree", "-r", "--name-only", "main"], remote), "chapter.tex\nmain.tex")
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
            let image = Data(repeating: 73, count: 1024 * 1024)
            try image.write(to: local.appendingPathComponent("image.bin"))
            _ = try git(["add", "."], local); _ = try git(["commit", "-m", "Attachment"], local); _ = try git(["push"], local)
            try "Local writing\nAnchor\n".write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            let recovery = local.deletingLastPathComponent().appendingPathComponent("Recovery")
            let first = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            XCTAssertTrue(try OverleafGitSync.publish(first))
            _ = try git(["pull", "--ff-only"], other)
            try "Local writing\nAnchor remote\n".write(to: other.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            try "New remote chapter\n".write(to: other.appendingPathComponent("chapter.tex"), atomically: true, encoding: .utf8)
            _ = try git(["add", "."], other); _ = try git(["commit", "-m", "Remote advanced"], other); _ = try git(["push"], other)
            let remoteHead = try git(["rev-parse", "main"], remote)
            let resumed = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            XCTAssertFalse(try OverleafGitSync.publish(resumed))
            // Simulate interruption after retaining the pending ref and before deleting the receipt.
            let pendingRef = OverleafSyncRecovery.pendingReference
            let localHead = try git(["rev-parse", pendingRef], local)
            _ = try git(["update-ref", OverleafSyncRecovery.reference(), localHead], local)
            _ = try git(["update-ref", "-d", pendingRef, localHead], local)
            let latest = try OverleafSyncRecovery.incorporatingConfirmedRemote(resumed, head: remoteHead)
            XCTAssertEqual(latest.head, remoteHead)
            XCTAssertEqual(latest.files["chapter.tex"], Data("New remote chapter\n".utf8))
            let oldImage = try XCTUnwrap(resumed.files["image.bin"]), newImage = try XCTUnwrap(latest.files["image.bin"])
            oldImage.withUnsafeBytes { old in newImage.withUnsafeBytes { new in XCTAssertEqual(old.baseAddress, new.baseAddress) } }
            XCTAssertThrowsError(try OverleafSyncRecovery.incorporatingConfirmedRemote(latest, head: first.originalHead))
            let afterRestart = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            XCTAssertEqual(afterRestart.head, remoteHead, "Receipt must retain the already confirmed descendant")
            XCTAssertEqual(afterRestart.files, latest.files)
            let writing = "Local writing revised\nAnchor\n"
            try writing.write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
            let outcome = try OverleafGitSync.synchronise(connection, root: local, recovery: recovery, transport: remote.path)
            XCTAssertEqual(outcome.prepared.head, remoteHead)
            let current = try OverleafSourceFiles.scan(local)
            let merged = try OverleafGitSync.reconcile(base: outcome.prepared.review.localFiles, current: current, result: outcome.prepared.files)
            XCTAssertEqual(merged["main.tex"], Data("Local writing revised\nAnchor remote\n".utf8))
            XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("main.tex"), encoding: .utf8), writing, "Transport never replaces active writing")
            for (path, bytes) in merged { try bytes.write(to: local.appendingPathComponent(path)) }
            _ = try git(["reset", "--mixed", outcome.prepared.head], local)
            let afterInstall = try OverleafGitSync.prepare(connection, root: local, recovery: recovery, transport: remote.path)
            XCTAssertEqual(afterInstall.head, remoteHead)
            XCTAssertEqual(try OverleafGitSync.reconcile(base: afterInstall.review.localFiles, current: OverleafSourceFiles.scan(local), result: afterInstall.files), merged, "Restart after installation must not duplicate either writer’s edits")
            XCTAssertEqual(try git(["rev-parse", "main"], remote), remoteHead, "Acknowledgement must not republish or add server commits")
            try OverleafSyncRecovery.finish(outcome.prepared)
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
            let current = try OverleafSourceFiles.scan(local, buffers: project.buffers)
            var incoming = current; incoming["main.tex"] = Data("Remote writing\n".utf8)
            let plan = try TeXProject.prepareLiveInstall(root: local, buffers: project.buffers, editRevision: project.editRevision,
                fileRevision: project.fileRevision, base: current, result: incoming, head: try git(["rev-parse", "HEAD"], local))
            project.updateBuffer("main.tex", to: "Typing after validation\n")
            XCTAssertThrowsError(try project.installLiveFiles(plan))
            XCTAssertEqual(project.buffers["main.tex"], "Typing after validation\n")
            XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("main.tex"), encoding: .utf8), "Alpha one\nBeta two\n")
            let latest = try OverleafSourceFiles.scan(local, buffers: project.buffers)
            let noOp = try TeXProject.prepareLiveInstall(root: local, buffers: project.buffers, editRevision: project.editRevision,
                fileRevision: project.fileRevision, base: latest, result: latest, head: try git(["rev-parse", "HEAD"], local))
            let revision = project.fileRevision
            try project.installLiveFiles(noOp)
            XCTAssertEqual(project.fileRevision, revision)
            XCTAssertEqual(project.buffers["main.tex"], "Typing after validation\n")
        }
    }
    @MainActor func testFileTreeRefreshAndMovePreserveUnsavedSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let figures = root.appendingPathComponent("Figures")
        try FileManager.default.createDirectory(at: figures, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("Original".utf8).write(to: root.appendingPathComponent("main.tex"))
        let project = try TeXProject(root, historyEnabled: false)
        project.updateBuffer("main.tex", to: "Unsaved edits")
        try Data("Asset".utf8).write(to: root.appendingPathComponent("figure.pdf"))
        let chapter = root.appendingPathComponent("chapter.tex")
        try Data(#"\section{Imported}"#.utf8).write(to: chapter)
        try await project.refreshFileTree()
        XCTAssertTrue(project.treeFiles.contains("figure.pdf"))
        XCTAssertEqual(project.buffers["chapter.tex"], #"\section{Imported}"#)
        XCTAssertTrue(project.move("figure.pdf", to: "Figures/figure.pdf"))
        XCTAssertEqual(project.treeFiles, ["Figures/figure.pdf", "chapter.tex", "main.tex"])
        try FileManager.default.removeItem(at: chapter)
        try await project.refreshFileTree()
        XCTAssertNil(project.buffers["chapter.tex"])
        let revision = project.fileRevision
        try await project.refreshFileTree()
        XCTAssertEqual(project.fileRevision, revision)
        XCTAssertEqual(project.selected, "main.tex")
        XCTAssertEqual(project.buffers["main.tex"], "Unsaved edits")
        XCTAssertTrue(project.dirty)
    }
    @MainActor func testLiveInstallRejectsExternalAttachmentChangesAfterValidation() throws {
        try fixture { local, _, _, _ in
            let file = local.appendingPathComponent("image.bin")
            try Data([1, 2]).write(to: file)
            let project = try TeXProject(local, historyEnabled: false)
            let current = try OverleafSourceFiles.scan(local, buffers: project.buffers)
            var incoming = current; incoming["image.bin"] = Data([3, 4])
            let plan = try TeXProject.prepareLiveInstall(root: local, buffers: project.buffers, editRevision: project.editRevision,
                fileRevision: project.fileRevision, base: current, result: incoming, head: try git(["rev-parse", "HEAD"], local))
            try Data([5, 6]).write(to: file)
            XCTAssertThrowsError(try project.installLiveFiles(plan))
            XCTAssertEqual(try Data(contentsOf: file), Data([5, 6]))
        }
    }
    @MainActor func testIncomingExactSourceMoveKeepsTheSelectedTabAndMainDocument() throws {
        try fixture { local, _, _, _ in
            let project = try TeXProject(local, historyEnabled: false)
            let identity = project.identity
            let current = try OverleafSourceFiles.scan(local, buffers: project.buffers)
            let incoming = ["folder/renamed.tex": current["main.tex"]!]
            let plan = try TeXProject.prepareLiveInstall(root: local, buffers: project.buffers, editRevision: project.editRevision,
                fileRevision: project.fileRevision, base: current, result: incoming, head: try git(["rev-parse", "HEAD"], local))
            try project.installLiveFiles(plan)
            XCTAssertEqual(project.identity, identity)
            XCTAssertEqual(project.main, "folder/renamed.tex")
            XCTAssertEqual(project.selected, "folder/renamed.tex")
            XCTAssertEqual(project.openFiles, ["folder/renamed.tex"])
            XCTAssertEqual(project.buffers["folder/renamed.tex"], "Alpha one\nBeta two\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathComponent("main.tex").path))
        }
    }
    @MainActor func testConnectedAutosavePersistsContinuousTypingWithoutWaitingForNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.tex")
        try "Initial source\n".write(to: file, atomically: true, encoding: .utf8)
        let project = try TeXProject(root, historyEnabled: false)
        var savedWhileTyping = false
        // No Git workspace or network response is required for durable local work.
        for index in 0..<10 {
            project.updateBuffer("main.tex", to: "Typed revision \(index)\n")
            try await Task.sleep(for: .milliseconds(200))
            let saved = try String(contentsOf: file, encoding: .utf8)
            if saved.hasPrefix("Typed revision ") { savedWhileTyping = true }
        }
        XCTAssertTrue(savedWhileTyping, "Continuous input must not postpone local saving until typing stops")
        let saved = try String(contentsOf: file, encoding: .utf8)
        let reopened = try TeXProject(root, historyEnabled: false)
        XCTAssertEqual(reopened.buffers["main.tex"], saved, "Restart reads the last complete local save without a network")
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
    func testExactSourceMovesDuringTransportKeepTheOtherWritersEdits() throws {
        let original = Data("A unique source\n".utf8), edited = Data("A unique source updated\n".utf8)
        let base = ["old.tex": original], moved = ["folder/new.tex": original]
        let expected = ["folder/new.tex": edited]
        XCTAssertEqual(try OverleafGitSync.reconcile(base: base, current: moved, result: ["old.tex": edited]), expected)
        XCTAssertEqual(try OverleafGitSync.reconcile(base: base, current: ["old.tex": edited], result: moved), expected)
        XCTAssertEqual(try OverleafGitSync.reconcile(base: base, current: moved, result: expected), expected)
        XCTAssertEqual(try OverleafGitSync.reconcile(base: base, current: moved, result: moved), moved)
        XCTAssertThrowsError(try OverleafGitSync.reconcile(base: base, current: moved, result: [:]))
        XCTAssertThrowsError(try OverleafGitSync.reconcile(base: base, current: [:], result: moved))
        XCTAssertThrowsError(try OverleafGitSync.reconcile(base: base, current: moved, result: ["elsewhere.tex": original]))
        XCTAssertThrowsError(try OverleafGitSync.reconcile(base: base, current: moved, result: ["old.tex": edited, "folder/new.tex": edited]))
        XCTAssertThrowsError(try OverleafGitSync.reconcile(base: base, current: ["one.tex": original, "two.tex": original], result: ["old.tex": edited]))
        XCTAssertThrowsError(try OverleafGitSync.reconcile(base: ["old.bin": original], current: ["new.bin": original], result: ["old.bin": edited]))
    }
    @MainActor func testFileLifecycleAndOfflineRestartConvergeThroughGit() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["REMILE_OVERLEAF_COLLABORATION_CHECKS"] == "1", "Optional collaboration scenario")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let remote = folder.appendingPathComponent("remote.git"), local = folder.appendingPathComponent("local"), other = folder.appendingPathComponent("other")
        _ = try git(["init", "--bare", "--initial-branch=main", remote.path], folder)
        _ = try git(["clone", remote.path, local.path], folder)
        let main = "\\documentclass{article}\n\\begin{document}\nMain manuscript\n\\end{document}\n"
        let note = "Alpha one\nBeta two\n"
        try main.write(to: local.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        try note.write(to: local.appendingPathComponent("note.tex"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."], local); _ = try git(["commit", "-m", "Initial"], local); _ = try git(["push", "origin", "main"], local)
        _ = try git(["clone", remote.path, other.path], folder)
        var project = try TeXProject(local, historyEnabled: false)
        let library = OverleafLibrary(directory: folder.appendingPathComponent("Library"))
        let connection = OverleafConnection(id: UUID(), projectID: String(repeating: "a", count: 24), name: "Fixture", account: "Test", branch: "main")
        var workspace = OverleafOnlineWorkspace(transport: remote.path)
        await workspace.start(project: project, library: library, connection: connection); await workspace.retry()
        XCTAssertTrue(workspace.connected, workspace.issue ?? "Not connected")
        library.offlineMode = true; await workspace.networkChanged()
        let checks = workspace.automationStatus["gitChecks"] as? Int
        project.updateBuffer("note.tex", to: note.replacingOccurrences(of: "Alpha one", with: "Alpha offline"))
        workspace.edited()
        // Save explicitly here. The normal scheduler-save contract has its own check.
        XCTAssertTrue(project.save())
        await workspace.flush()
        XCTAssertEqual(workspace.automationStatus["gitChecks"] as? Int, checks)
        await workspace.stop()
        _ = try git(["mv", "note.tex", "renamed.tex"], other)
        try "Remote new source\n".write(to: other.appendingPathComponent("remote.tex"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."], other); _ = try git(["commit", "-m", "Rename and add while offline"], other); _ = try git(["push"], other)
        project = try TeXProject(local, historyEnabled: false)
        workspace = OverleafOnlineWorkspace(transport: remote.path)
        library.offlineMode = false
        await workspace.start(project: project, library: library, connection: connection); await workspace.retry()
        XCTAssertTrue(workspace.connected, workspace.issue ?? "Not connected after restart")
        XCTAssertFalse(workspace.requiresGitReview)
        XCTAssertNil(project.buffers["note.tex"])
        XCTAssertEqual(project.buffers["renamed.tex"], note.replacingOccurrences(of: "Alpha one", with: "Alpha offline"))
        XCTAssertEqual(project.buffers["remote.tex"], "Remote new source\n")
        _ = try git(["pull", "--ff-only"], other)
        _ = try git(["rm", "remote.tex"], other)
        _ = try git(["commit", "-m", "Delete unchanged source"], other); _ = try git(["push"], other)
        project.newFile(); XCTAssertTrue(project.finishNewItem("local.tex"))
        project.updateBuffer("local.tex", to: "Local new source\n"); workspace.edited()
        await workspace.retry()
        XCTAssertTrue(workspace.connected, workspace.issue ?? "Not connected after deletion")
        XCTAssertNil(project.buffers["remote.tex"])
        XCTAssertEqual(try git(["show", "main:local.tex"], remote), "Local new source")
        XCTAssertEqual(project.buffers["main.tex"], main)
        XCTAssertEqual(workspace.pendingDocumentCount, 0)
        await workspace.stop()
    }
    @MainActor func testOnDeviceChoiceAndOfflineStatusAreIndependent() async {
        let suite = "remile.git-test." + UUID().uuidString
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        let id = UUID()
        XCTAssertTrue(OverleafSyncPreference.live(id, store: store))
        OverleafSyncPreference.choose(false, for: id, store: store)
        XCTAssertFalse(OverleafSyncPreference.live(id, store: store))
        let workspace = OverleafOnlineWorkspace()
        await workspace.stop()
        XCTAssertFalse(workspace.enabled)
        XCTAssertEqual(workspace.automationStatus["transport"] as? String, "git")
        XCTAssertEqual(workspace.automationStatus["mode"] as? String, "on-device")
        XCTAssertFalse(workspace.automationStatus["confirmed"] as? Bool ?? true)
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
        let workspace = OverleafOnlineWorkspace(transport: remote.path)
        await workspace.start(project: project, library: library, connection: connection)
        await workspace.retry()
        XCTAssertTrue(workspace.connected, workspace.issue ?? "Not connected")
        XCTAssertEqual(workspace.automationStatus["mode"] as? String, "online")
        let idleCheck = try XCTUnwrap(workspace.automationStatus["nextCheckAt"] as? TimeInterval)
        XCTAssertGreaterThan(idleCheck - Date().timeIntervalSince1970, 25, "Opening an unchanged project must not start rapid polling")
        XCTAssertLessThanOrEqual(idleCheck - Date().timeIntervalSince1970, 30)
        project.updateBuffer("main.tex", to: source.replacingOccurrences(of: "First", with: "Local"))
        try (source + "% Remote collaborator\n").write(to: other.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."], other); _ = try git(["commit", "-m", "Independent simultaneous edit"], other); _ = try git(["push"], other)
        workspace.edited()
        try await Task.sleep(for: .milliseconds(20))
        let sleepers = workspace.automationStatus["schedulerStarts"] as? Int
        for _ in 0..<100 { workspace.edited() }
        XCTAssertEqual(workspace.automationStatus["schedulerStarts"] as? Int, sleepers, "Typing should reuse a sleeper that already wakes before the next edit deadline")
        let uploadDeadline = ContinuousClock.now.advanced(by: .seconds(22))
        while workspace.pendingDocumentCount > 0, ContinuousClock.now < uploadDeadline {
            try await Task.sleep(for: .milliseconds(150))
        }
        XCTAssertEqual(workspace.pendingDocumentCount, 0, "Local edits must publish automatically before the idle remote check")
        XCTAssertTrue(workspace.connected, workspace.issue ?? "Not connected")
        XCTAssertFalse(workspace.requiresGitReview)
        XCTAssertEqual(project.buffers["main.tex"], source.replacingOccurrences(of: "First", with: "Local") + "% Remote collaborator\n")
        let collaborationCheck = try XCTUnwrap(workspace.automationStatus["nextCheckAt"] as? TimeInterval)
        XCTAssertLessThanOrEqual(collaborationCheck - Date().timeIntervalSince1970, 15, "Incoming work keeps collaboration responsive")
        let checks = workspace.automationStatus["gitChecks"] as? Int
        workspace.setVisible(false); workspace.setVisible(true); workspace.foregrounded()
        await workspace.flush()
        XCTAssertEqual(workspace.automationStatus["gitChecks"] as? Int, checks, "Quick window changes must not trigger repeated fetches")
        XCTAssertEqual(try git(["show", "main:main.tex"], remote), project.buffers["main.tex"]?.trimmingCharacters(in: .whitespacesAndNewlines))
        _ = try git(["pull", "--ff-only"], other)
        var updated = project.buffers["main.tex"]!.replacingOccurrences(of: "Local", with: "Remote")
        try updated.write(to: other.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."], other); _ = try git(["commit", "-m", "Remote"], other); _ = try git(["push"], other)
        project.compiling = true
        await workspace.retry()
        project.compiling = false
        XCTAssertEqual(project.buffers["main.tex"], updated)
        XCTAssertEqual(project.identity, identity)
        XCTAssertEqual(workspace.pendingDocumentCount, 0)
        _ = try git(["pull", "--ff-only"], other)
        project.updateBuffer("main.tex", to: updated.replacingOccurrences(of: "Remote", with: "Local conflict"))
        updated = updated.replacingOccurrences(of: "Remote", with: "Remote conflict")
        try updated.write(to: other.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."], other); _ = try git(["commit", "-m", "Overlapping writing"], other); _ = try git(["push"], other)
        workspace.edited(); await workspace.retry()
        XCTAssertTrue(workspace.requiresGitReview)
        let conflictChecks = workspace.automationStatus["gitChecks"] as? Int
        workspace.edited()
        XCTAssertTrue(workspace.requiresGitReview, "Repeated notifications must not retry an unchanged conflict")
        project.newFile(); XCTAssertTrue(project.finishNewItem("additional.tex"))
        workspace.edited()
        XCTAssertFalse(workspace.requiresGitReview, "A new file operation can retry a recoverable conflict too")
        project.updateBuffer("main.tex", to: updated)
        workspace.edited()
        XCTAssertFalse(workspace.requiresGitReview, "New writing retries a source conflict without a comparison click")
        await workspace.flush()
        XCTAssertEqual(workspace.automationStatus["gitChecks"] as? Int, conflictChecks, "Automatic retry must retain request spacing")
        await workspace.retry()
        XCTAssertTrue(workspace.connected, workspace.issue ?? "Not connected after editing")
        XCTAssertEqual(workspace.pendingDocumentCount, 0)
        library.offlineMode = true
        await workspace.networkChanged()
        let checksBeforeLocalSave = workspace.automationStatus["gitChecks"] as? Int
        project.updateBuffer("main.tex", to: updated + "% Saved without network\n")
        workspace.edited()
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertFalse(project.dirty)
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("main.tex"), encoding: .utf8), project.buffers["main.tex"])
        XCTAssertEqual(workspace.automationStatus["localSaved"] as? Bool, true)
        XCTAssertEqual(workspace.automationStatus["gitChecks"] as? Int, checksBeforeLocalSave)
        let unavailable = folder.appendingPathComponent("unavailable.git")
        try FileManager.default.moveItem(at: remote, to: unavailable)
        library.offlineMode = false
        await workspace.retry(); await workspace.retry()
        let failedCheck = try XCTUnwrap(workspace.automationStatus["nextCheckAt"] as? TimeInterval)
        XCTAssertGreaterThan(failedCheck - Date().timeIntervalSince1970, 25)
        let failedTransfers = try XCTUnwrap(workspace.automationStatus["lastGitTransfers"] as? [[String: Any]])
        XCTAssertEqual(failedTransfers.count, 1)
        XCTAssertEqual(failedTransfers.first?["phase"] as? String, "fetch")
        XCTAssertEqual(failedTransfers.first?["succeeded"] as? Bool, false)
        library.offlineMode = true
        await workspace.networkChanged()
        try FileManager.default.moveItem(at: unavailable, to: remote)
        library.offlineMode = false
        await workspace.networkChanged()
        let recoveryCheck = try XCTUnwrap(workspace.automationStatus["nextCheckAt"] as? TimeInterval)
        XCTAssertLessThanOrEqual(recoveryCheck - Date().timeIntervalSince1970, 15, "Restored connectivity should release a transport backoff")
        await workspace.stop()
        project.updateBuffer("main.tex", to: updated + "% Offline draft\n")
        await workspace.flush()
        XCTAssertEqual(try git(["show", "main:main.tex"], remote), updated.trimmingCharacters(in: .whitespacesAndNewlines))
    }

}
