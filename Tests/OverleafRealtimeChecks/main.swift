import Foundation
let output = URL(fileURLWithPath: CommandLine.arguments[1])
var count = 0
func require(_ condition: Bool, _ message: String) { precondition(condition, message); count += 1; print("PASS: " + message) }
func refuses(_ message: String, _ action: () throws -> Void) {
    do { try action(); fatalError(message) } catch { require(true, message) }
}
let key = OverleafLive.Key(profile: UUID(), project: "6ad72e207e5cd74f01fe6b18", document: "6ad72e207e5cd74f01fe6b19")
let base = OverleafLive.Snapshot(version: 7, text: "Original 🧭 text\n")
func ready(local: String? = nil) throws -> OverleafLive.State {
    var state = try OverleafLive.State(key: key, base: base, local: local)
    try state.resume(base, epoch: state.epoch); return state
}
func receipt(_ op: OverleafLive.Submission, version: Int? = nil) -> OverleafLive.Receipt {
    .init(id: op.id, epoch: op.epoch, key: op.key, version: version ?? op.baseVersion + 1)
}
func apply(_ edit: OverleafLive.Edit, to before: String) -> String {
    let text = before as NSString
    precondition(text.substring(with: NSRange(location: edit.offset, length: edit.deleted.utf16.count)) == edit.deleted)
    return text.replacingCharacters(in: NSRange(location: edit.offset, length: edit.deleted.utf16.count), with: edit.inserted)
}
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (before, after) in [("", "new"), ("gone", ""), ("🧭 alpha", "🧭 beta"), ("e\u{301} is here", "e\u{301} is there"), ("a\r\nb\n", "a\r\nc\n"), ("a🧭b", "a🧪b"), ("same", "same")] {
    let patch = try OverleafLive.Edit.between(before, after)
    require(apply(patch, to: before) == after, "Bounded UTF-16 replacement round-trips text")
}
refuses("Binary/control text is not silently treated as source") { _ = try ready(local: "binary\0data") }
refuses("Large text is rejected before diffing") { _ = try ready(local: String(repeating: "x", count: OverleafLive.textLimit + 1)) }
refuses("Invalid IDs cannot bind a session") { _ = try OverleafLive.State(key: .init(profile: key.profile, project: "../bad", document: key.document), base: base) }
refuses("Trailing newline in an ID is rejected") { _ = try OverleafLive.State(key: .init(profile: key.profile, project: key.project + "\n", document: key.document), base: base) }
var rejection = try ready(local: "Restored source")
let rejectionOp = try rejection.submission(rejecting: true)!
let rejectionWire = OverleafLiveWire.update(rejectionOp)
require(rejectionWire["op"].array!.allSatisfy { $0["u"] == .bool(true) }, "Review inverse edits use Overleaf's undo/rejection marker")
let rejectionSaved = try JSONDecoder().decode(OverleafLive.Checkpoint.self, from: JSONEncoder().encode(rejection.checkpoint))
try rejectionSaved.validate()
require(rejectionSaved.inFlight?.rejecting == true, "Rejection intent survives a durable checkpoint round trip")
let normalOp = try ready(local: "Ordinary edit").checkpoint
require(try JSONDecoder().decode(OverleafLive.Checkpoint.self, from: JSONEncoder().encode(normalOp)).inFlight == nil, "Older checkpoints without rejection metadata still decode")
var state = try ready(local: "First edit")
let first = try state.submission()!
require(try state.submission() == nil, "Only one operation may await acknowledgement")
try state.edited("Second edit during upload")
require(state.acknowledge(receipt(first)) && state.local == "Second edit during upload" && state.base.text == "First edit", "Acknowledgement preserves newer local edits")
require(!state.acknowledge(receipt(first)), "Duplicate acknowledgement is ignored")
let second = try state.submission()!
require(second.baseVersion == 8 && second.after == state.local, "Next operation uses the acknowledged version")
let wrong = OverleafLive.Receipt(id: second.id, epoch: second.epoch, key: .init(profile: UUID(), project: key.project, document: key.document), version: 9)
require(!state.acknowledge(wrong), "Another account cannot acknowledge this operation")
state.disconnect()
require(!state.acknowledge(receipt(second)) && state.phase == .disconnected, "Late acknowledgement cannot revive a disconnected session")
try state.resume(.init(version: 9, text: second.after), epoch: state.epoch)
require(state.inFlight == nil && state.local == second.after && state.base.version == 9, "Lost acknowledgement is reconciled from a fresh snapshot without replay")
var conflict = try ready(local: "Offline local draft")
conflict.disconnect(); let epoch = conflict.epoch
try conflict.resume(.init(version: 8, text: "Remote draft"), epoch: epoch)
require(conflict.phase == .reviewRequired && conflict.local == "Offline local draft", "Reconnect preserves a divergent local draft for review")
refuses("Divergent changes cannot publish automatically") { _ = try conflict.submission() }
refuses("A stale merge cannot replace newer local edits") { try conflict.resolveReview(remote: .init(version: 8, text: "Remote draft"), merged: "Merged", expectedLocal: "Old draft") }
try conflict.resolveReview(remote: .init(version: 8, text: "Remote draft"), merged: "Reviewed merge", expectedLocal: "Offline local draft")
require(conflict.local == "Reviewed merge" && conflict.phase == .ready, "Only an explicit current review installs merged text")
var remoteOnly = try ready()
try remoteOnly.resume(.init(version: 8, text: "Remote changed"), epoch: remoteOnly.epoch)
require(remoteOnly.local == base.text && remoteOnly.phase == .reviewRequired, "Remote-only changes also require manual review")
var stale = try ready(local: "Draft")
let oldEpoch = stale.epoch; stale.disconnect()
refuses("Snapshots from an old connection are rejected") { try stale.resume(base, epoch: oldEpoch) }
refuses("Older server versions are rejected") { try stale.resume(.init(version: 6, text: base.text), epoch: stale.epoch) }
var versionMismatch = try ready(local: "Draft")
let pending = try versionMismatch.submission()!
require(!versionMismatch.acknowledge(receipt(pending, version: 100)) && versionMismatch.phase == .disconnected && versionMismatch.local == "Draft", "Unexpected acknowledgement versions force reconciliation without deleting drafts")
let journal = output.appendingPathComponent("recovery/checkpoint.json")
try OverleafLiveJournal.save(versionMismatch.checkpoint, to: journal)
let saved = try OverleafLiveJournal.load(from: journal, for: key)
let restored = try OverleafLive.State(checkpoint: saved)
require(restored.local == "Draft" && restored.inFlight?.id == pending.id && restored.phase == .disconnected, "Crash recovery retains an uncertain operation and starts disconnected")
refuses("A journal cannot be loaded for another account") { _ = try OverleafLiveJournal.load(from: journal, for: .init(profile: UUID(), project: key.project, document: key.document)) }
let otherKey = OverleafLive.Key(profile: UUID(), project: key.project, document: key.document)
let otherState = try OverleafLive.State(key: otherKey, base: base)
refuses("An existing recovery file cannot be overwritten by another account") { try OverleafLiveJournal.save(otherState.checkpoint, to: journal) }
require(try OverleafLiveJournal.load(from: journal, for: key).local == "Draft", "Rejected identity changes preserve the original recovery file")
let perms = try FileManager.default.attributesOfItem(atPath: journal.path)[.posixPermissions] as? Int
require(perms == 0o600, "Recovery checkpoint is private")
let lock = output.appendingPathComponent("recovery/writer.lock")
var owner: OverleafLiveWriterLease? = try OverleafLiveWriterLease(file: lock)
refuses("A second writer cannot acquire the same project lock") { _ = try OverleafLiveWriterLease(file: lock) }
owner = nil
let nextOwner = try OverleafLiveWriterLease(file: lock)
require(owner == nil, "Writer lease is reusable after its owner releases it")
withExtendedLifetime(nextOwner) { }
let symlink = output.appendingPathComponent("recovery/linked.lock")
try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: lock)
refuses("Writer lock does not follow a symlink") { _ = try OverleafLiveWriterLease(file: symlink) }

// Reconciliation and review use the same bounded edits, never a whole-document local win.
let splitBase = "alpha\nkeep one\nbeta\nkeep two\ngamma\n"
let splitLocal = "ALPHA\nkeep one\nbeta\nkeep two\nGAMMA\n"
let splitRemote = "alpha\nkeep one\nBETA\nkeep two\ngamma\n"
require(try OverleafLiveText.merge(base: splitBase, local: splitLocal, remote: splitRemote) == "ALPHA\nkeep one\nBETA\nkeep two\nGAMMA\n", "Disjoint changes around an intervening remote edit combine safely")
require(try OverleafLiveText.merge(base: "alpha beta gamma", local: "ALPHA beta gamma", remote: "alpha beta GAMMA") == "ALPHA beta GAMMA", "Independent character changes on one line still combine")
refuses("Different insertions at the same position remain a conflict") { _ = try OverleafLiveText.merge(base: "alpha", local: "Lalpha", remote: "Ralpha") }
refuses("Overlapping replacements remain a conflict") { _ = try OverleafLiveText.merge(base: splitBase, local: splitLocal, remote: splitBase.replacingOccurrences(of: "alpha", with: "other")) }
require(try OverleafLiveText.merge(base: splitBase, local: splitLocal, remote: "ALPHA\nkeep one\nBETA\nkeep two\ngamma\n") == "ALPHA\nkeep one\nBETA\nkeep two\nGAMMA\n", "Identical changes are included only once")
for (before, after) in [(splitLocal, splitRemote), ("", "a\nb\n"), ("a\nb\n", ""), ("a🧭b\nkeep\ne\u{301}\r\n", "a🧪b\nkeep\ne\u{301} changed\r\n"), ("x\nx\nx\n", "x\ny\nx\n"), ("last", "last\n"), ("a\nb", "a\nb\nc")] {
    let edits = try OverleafLiveText.edits(from: before, to: after)
    require(try OverleafLiveText.replacing(before, edits: edits) == after, "Section edits reconstruct exact text including Unicode and newline boundaries")
}
let reviewEdits = try OverleafLiveText.edits(from: splitLocal, to: splitRemote)
require(try reviewEdits.count == 3 && (OverleafLiveText.replacing(splitLocal, edits: [reviewEdits[1]])) == "ALPHA\nkeep one\nBETA\nkeep two\nGAMMA\n", "A section choice keeps the other local sections unchanged")
let largeBefore = (0..<2_001).map { "line \($0)\n" }.joined(), largeAfter = (0..<2_001).map { "changed \($0)\n" }.joined()
require(try OverleafLiveText.edits(from: largeBefore, to: largeAfter).count == 1, "Complex diffs use a bounded conservative fallback")

actor FakeLiveTransport: OverleafLiveTransport {
    var calls = 0
    var submissions = 0
    var current = base
    func snapshot(for key: OverleafLive.Key, epoch: UUID) async throws -> OverleafLive.Snapshot { calls += 1; return current }
    func submit(_ operation: OverleafLive.Submission) async throws -> OverleafLive.Receipt {
        submissions += 1; current = .init(version: operation.baseVersion + 1, text: operation.after); return receipt(operation)
    }
    func stop(epoch: UUID) async { }
    func counts() -> (Int, Int) { (calls, submissions) }
}
actor HeldLiveTransport: OverleafLiveTransport {
    private var pending: (OverleafLive.Submission, CheckedContinuation<OverleafLive.Receipt, Error>)?
    private var started: CheckedContinuation<Void, Never>?
    func snapshot(for key: OverleafLive.Key, epoch: UUID) async throws -> OverleafLive.Snapshot { base }
    func submit(_ operation: OverleafLive.Submission) async throws -> OverleafLive.Receipt {
        try await withCheckedThrowingContinuation { continuation in
            pending = (operation, continuation); started?.resume(); started = nil
        }
    }
    func waitForSubmission() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func stop(epoch: UUID) async {
        if let value = pending, value.0.epoch == epoch { pending = nil; value.1.resume(throwing: CancellationError()) }
    }
}
require(try OverleafLiveWire.handshake("safe-sid_123:25:60:websocket,xhr-polling") == "safe-sid_123", "Handshake accepts only a bounded WebSocket-capable session")
for bad in ["../../bad:25:60:websocket", "sid:0:60:websocket", "sid:25:-1:websocket", "sid:25:60:xhr-polling", "sid:25:60:websocket:extra"] {
    refuses("Malformed or unsupported handshake is rejected") { _ = try OverleafLiveWire.handshake(bad) }
}
let eventArgs: [OverleafLiveWire.JSON] = [.string(key.document), .int(-1), .object(["encodeRanges": .bool(true)])]
let eventFrame = try OverleafLiveWire.event("joinDoc", eventArgs, id: 3)
require(try OverleafLiveWire.decode(eventFrame) == .event("joinDoc", eventArgs), "Legacy event framing preserves arguments and colons")
require(try OverleafLiveWire.decode("6:::3+[null,[\"first\",\"last\"],7]") == .acknowledgement(3, [.null, .array([.string("first"),.string("last")]),.int(7)]), "RPC acknowledgement is parsed independently of applied updates")
require(try OverleafLiveWire.decode("6:::20") == .acknowledgement(20, []), "An empty successful RPC acknowledgement does not disconnect the live session")
require(try OverleafLiveWire.decode("2::") == .heartbeat, "Server heartbeat is recognised")
refuses("Other Socket.IO namespaces are refused") { _ = try OverleafLiveWire.decode("5::/other:{\"name\":\"joinDoc\",\"args\":[]}") }
let decoded = try OverleafLiveWire.snapshot([.array([.string("cafÃ©"), .string("end")]), .int(4)])
require(decoded.text == "café\nend" && decoded.version == 4, "Legacy Latin-1 wrapped UTF-8 lines decode without changing newlines")
func op(_ offset: Int, insert: String) -> OverleafLiveWire.JSON { .object(["p": .int(offset), "i": .string(insert)]) }
require(try OverleafLiveText.applying([op(3, insert:"!")],to:"a🧭b") == "a🧭!b", "Incoming operations use UTF-16 offsets")
refuses("An operation cannot split a surrogate pair") { _ = try OverleafLiveText.applying([op(2,insert:"!")],to:"a🧭b") }
for text in ["", "ASCII", "한글 αβ", "e\u{301}", "👩🏽‍💻", "a\r\nb"] {
    let units = Array(text.utf16)
    for offset in 0...text.utf16.count {
        let range = Range(NSRange(location: offset, length: 0), in: text)
        let splitsSurrogate = offset > 0 && offset < units.count && (0xD800...0xDBFF).contains(units[offset - 1]) && (0xDC00...0xDFFF).contains(units[offset])
        if let range, !splitsSurrogate {
            var expected = text; expected.replaceSubrange(range, with: "!")
            require(try OverleafLiveText.applying([op(offset, insert: "!")], to: text) == expected, "Incoming edits retain Unicode and grapheme boundaries")
        } else {
            refuses("Incoming edits reject invalid UTF-16 boundaries") { _ = try OverleafLiveText.applying([op(offset, insert: "!")], to: text) }
        }
    }
}
let batchText = String(repeating: "한글 🧭 ", count: 1000)
let batch = (0..<100).map { op(batchText.utf16.count + $0, insert: "x") }
require(try OverleafLiveText.applying(batch, to: batchText) == batchText + String(repeating: "x", count: 100), "A remote edit batch keeps sequential UTF-16 offsets")
refuses("Mismatched deletion text cannot corrupt a document") { _ = try OverleafLiveText.applying([.object(["p":.int(0),"d":.string("wrong")])],to:"right") }
require(try OverleafLiveText.merge(base:"alpha beta gamma",local:"ALPHA beta gamma",remote:"alpha beta GAMMA") == "ALPHA beta GAMMA", "Non-overlapping edits on the same line reconcile in both directions")
require(try OverleafLiveText.merge(base:"a🧭b",local:"A🧭b",remote:"a🧭B") == "A🧭B", "Concurrent edits preserve astral text between changes")
refuses("Concurrent replacement of the same range requires review") { _ = try OverleafLiveText.merge(base:"alpha",local:"local",remote:"remote") }
refuses("Inserts at the same offset require an explicit choice") { _ = try OverleafLiveText.merge(base:"ab",local:"aLb",remote:"aRb") }
let doc: OverleafLiveWire.JSON = .object(["_id": .string(key.document), "name": .string("main.tex")])
let projectTree: OverleafLiveWire.JSON = .object(["_id": .string(key.project), "rootFolder": .array([.object(["name": .string("rootFolder"), "docs": .array([doc])])])])
require(try OverleafLiveWire.documents(projectTree,expectedID:key.project) == [.init(id:key.document,path:"main.tex")], "Project tree binds only the expected project and safe relative paths")
refuses("A different project's tree is refused") { _ = try OverleafLiveWire.documents(projectTree,expectedID:key.document) }
let traversal: OverleafLiveWire.JSON = .object(["_id": .string(key.project), "rootFolder": .array([.object(["docs": .array([.object(["_id":.string(key.document),"name":.string("../main.tex")])])])])])
refuses("Remote filenames cannot traverse local folders") { _ = try OverleafLiveWire.documents(traversal,expectedID:key.project) }
var replayState = try ready(local: "Original 🧭 text!\n")
let originalReplay = try replayState.submission(source: "session-one")!
let replaySaved = replayState.checkpoint
var resumedReplay = try OverleafLive.State(checkpoint: replaySaved)
try resumedReplay.edited(base.text) // Undo while the first upload is unconfirmed.
let replayed = try resumedReplay.replay(base, source: "session-two")
require(replayed.id == originalReplay.id && replayed.baseVersion == originalReplay.baseVersion && replayed.edit == originalReplay.edit, "Recovery replays the original operation and version rather than inventing another edit")
require(replayed.sources == ["session-one", "session-two"] && resumedReplay.local == base.text, "Recovery retains prior session IDs and a newer local Undo")
require(OverleafLiveWire.update(replayed)["dupIfSource"].array?.count == 2, "The wire asks the server to deduplicate every earlier source")
let recoveredCheckpoint = try JSONDecoder().decode(OverleafLive.Checkpoint.self, from: JSONEncoder().encode(resumedReplay.checkpoint))
require(recoveredCheckpoint.inFlight?.sources == replayed.sources, "Deduplication intent survives a journal round trip")
let actual: OverleafLiveWire.JSON = .object(["v": .int(base.version), "op": OverleafLiveWire.update(originalReplay)["op"], "meta": .object(["source": .string("session-one")])])
let recoveredHistory = OverleafLiveWire.CatchUp(snapshot: .init(version: base.version + 1, text: originalReplay.after), operations: [actual])
require(try recoveredHistory.contains(originalReplay, base: base), "Complete server history identifies an applied operation even when its ACK was lost")
refuses("History gaps cannot clear uncertain intent") { _ = try OverleafLiveWire.CatchUp(snapshot: .init(version: base.version + 2, text: originalReplay.after), operations: [actual]).contains(originalReplay, base: base) }
refuses("History text must reconstruct the returned snapshot") { _ = try OverleafLiveWire.CatchUp(snapshot: .init(version: base.version + 1, text: "wrong"), operations: [actual]).contains(originalReplay, base: base) }
var legacyPending = try OverleafLive.State(checkpoint: replaySaved)
refuses("Unversioned stale snapshots cannot be replayed") { _ = try legacyPending.replay(.init(version: base.version - 1, text: base.text), source: "session-two") }

require(try OverleafLiveText.applying([.object(["p": .int(1), "c": .string("🧭"), "t": .string("thread")])], to: "a🧭b") == "a🧭b", "A comment anchor advances history without changing source text")
refuses("A comment anchor must match the current source") { _ = try OverleafLiveText.applying([.object(["p": .int(0), "c": .string("wrong")])], to: "a🧭b") }

let semaphore = DispatchSemaphore(value: 0)
Task.detached {
    do {
        let suite = "remile.live-check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let gate = NetworkAccessGate(defaults: defaults), transport = FakeLiveTransport()
        let coordinator = try OverleafLiveCoordinator(state: OverleafLive.State(key: key, base: base), transport: transport, gate: gate, directory: output.appendingPathComponent("coordinator"))
        try await coordinator.edit("Persisted draft")
        gate.setOffline(true)
        do { try await coordinator.reconnect(); fatalError("Offline reconnect reached transport") } catch is NetworkAccessGate.Offline { }
        do { try await coordinator.publishOne(); fatalError("Offline publish reached transport") } catch is NetworkAccessGate.Offline { }
        let blockedCounts = await transport.counts()
        require(blockedCounts.0 == 0 && blockedCounts.1 == 0, "Offline gate refuses transport calls before any I/O")
        gate.setOffline(false); try await coordinator.reconnect(); try await coordinator.publishOne()
        let published = await coordinator.current()
        require(published.local == "Persisted draft" && published.base.version == 8 && published.inFlight == nil, "Coordinator journals and publishes a correlated fake operation")
        await coordinator.stop()
        require(await coordinator.phase() == .disconnected, "Stopping the coordinator invalidates the connection")
        let recovered = try OverleafLiveJournal.load(from: OverleafLiveJournal.checkpoint(for: key, under: output.appendingPathComponent("coordinator")), for: key)
        require(recovered.local == "Persisted draft", "Coordinator edits survive reopening the recovery journal")
        let heldTransport = HeldLiveTransport()
        let held = try OverleafLiveCoordinator(state: OverleafLive.State(key: key, base: base, local: "Unsent draft"), transport: heldTransport, gate: gate, directory: output.appendingPathComponent("held"))
        try await held.reconnect()
        let upload = Task { try await held.publishOne() }
        await heldTransport.waitForSubmission()
        gate.setOffline(true)
        do { try await upload.value; fatalError("Offline did not cancel the held upload") } catch { }
        let retained = await held.current()
        require(await held.phase() == .disconnected && retained.local == "Unsent draft" && retained.inFlight != nil, "Offline cancels an active transport while retaining the uncertain operation")
        let retainedDisk = try OverleafLiveJournal.load(from: OverleafLiveJournal.checkpoint(for: key, under: output.appendingPathComponent("held")), for: key)
        require(retainedDisk.inFlight?.id == retained.inFlight?.id, "Pending intent is on disk before an upload can be cancelled")
        gate.setOffline(false)
        try await held.reconnect()
        let reconnected = await held.current()
        require(await held.phase() == .ready && reconnected.local == "Unsent draft", "Reconnect renews the offline lease and preserves the draft")
        await held.stop()
        defaults.removePersistentDomain(forName: suite)
        print("Passed \(count) realtime preparation checks; fake transport only, no live connection")
        semaphore.signal()
    } catch { print("FAILED:", error); exit(1) }
}
semaphore.wait()
