import Foundation

actor LiveFixtureChannel: OverleafLiveChannel {
    nonisolated let events: AsyncStream<OverleafLiveSocket.Event>
    nonisolated private let output: AsyncStream<OverleafLiveSocket.Event>.Continuation
    private let projectID: String, documentID: String
    private var remote: OverleafLive.Snapshot
    private var hold = false
    private var pending: (OverleafLive.Submission, OverleafLive.Snapshot)?
    private(set) var submissions = 0
    init(project: String, document: String, text: String) {
        projectID = project; documentID = document; remote = .init(version: 1, text: text)
        let stream = AsyncStream<OverleafLiveSocket.Event>.makeStream()
        events = stream.stream; output = stream.continuation
    }
    func connect() -> OverleafLiveWire.JSON {
        .object(["_id": .string(projectID), "rootFolder": .array([.object(["name": .string("rootFolder"), "docs": .array([.object(["_id": .string(documentID), "name": .string("main.tex")])])])])])
    }
    func join(_ document: String) throws -> OverleafLive.Snapshot { precondition(document == documentID); return remote }
    func leave(_ document: String) { }
    func submit(_ operation: OverleafLive.Submission) throws {
        submissions += 1; precondition(operation.baseVersion == remote.version)
        if hold { pending = (operation, remote); return }
        try apply(operation, base: remote)
    }
    private func apply(_ operation: OverleafLive.Submission, base: OverleafLive.Snapshot) throws {
        let merged = try OverleafLiveText.merge(base: base.text, local: operation.after, remote: remote.text)
        let version = remote.version; remote = .init(version: version + 1, text: merged)
        output.yield(.init(name: "otUpdateApplied", args: [.object(["doc": .string(documentID), "v": .int(version)])]))
    }
    func holdSubmissions() { hold = true }
    func release() throws { hold = false; if let pending { self.pending = nil; try apply(pending.0, base: pending.1) } }
    func remoteEdit(_ text: String) throws {
        let edit = try OverleafLive.Edit.between(remote.text, text)
        let operation = OverleafLive.Submission(id: UUID(), epoch: UUID(), key: .init(profile: UUID(), project: projectID, document: documentID), baseVersion: remote.version, edit: edit, after: text)
        let event = OverleafLiveWire.update(operation)
        remote = .init(version: remote.version + 1, text: text)
        output.yield(.init(name: "otUpdateApplied", args: [event]))
    }
    func treeChanged() { output.yield(.init(name: "renameEntity", args: [])) }
    func text() -> String { remote.text }
    func stop() { output.finish() }
}

actor MultiLiveFixtureChannel: OverleafLiveChannel {
    nonisolated let events: AsyncStream<OverleafLiveSocket.Event>
    private let output: AsyncStream<OverleafLiveSocket.Event>.Continuation
    let project: String
    var texts: [String: OverleafLive.Snapshot]
    var pending: [String: OverleafLive.Submission] = [:]
    init(project: String, text: String) {
        self.project = project; texts = ["000000000000000000000001": .init(version: 1, text: text), "000000000000000000000002": .init(version: 1, text: text)]
        let stream = AsyncStream<OverleafLiveSocket.Event>.makeStream(); events = stream.stream; output = stream.continuation
    }
    func connect() -> OverleafLiveWire.JSON {
        .object(["_id": .string(project), "rootFolder": .array([.object(["docs": .array([.object(["_id": .string("000000000000000000000001"), "name": .string("main.tex")]), .object(["_id": .string("000000000000000000000002"), "name": .string("second.tex")])])])])])
    }
    func join(_ document: String) -> OverleafLive.Snapshot { texts[document]! }
    func leave(_ document: String) {}
    func submit(_ operation: OverleafLive.Submission) { pending[operation.key.document] = operation }
    var pendingCount: Int { pending.count }
    func confirm(_ document: String) {
        let op = pending.removeValue(forKey: document)!, version = texts[document]!.version
        texts[document] = .init(version: version + 1, text: op.after)
        output.yield(.init(name: "otUpdateApplied", args: [.object(["doc": .string(document), "v": .int(version)])]))
    }
    func stop() { output.finish() }
}

@MainActor func checkLiveWorkspace(output: URL, check: (Bool, String) -> Void) async throws {
    let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    var online = original; online[NetworkAccessGate.preference] = false
    UserDefaults.standard.setVolatileDomain(online, forName: UserDefaults.argumentDomain)
    defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
    let projectID = "6ad72e207e5cd74f01fe6b18", docID = "6ad72e207e5cd74f01fe6b19"
    let prefix = "\\documentclass{article}\n"
    let base = prefix + "alpha beta gamma\n"
    func fixture(_ name: String) throws -> (OverleafLibrary, TeXProject, OverleafConnection) {
        let folder = output.appendingPathComponent(name)
        let connection = OverleafConnection(id: UUID(), profileID: UUID(), projectID: projectID, name: "Fixture", account: "Fixture", branch: "master")
        let root = folder.appendingPathComponent("Projects/" + connection.id.uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try base.write(to: root.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        _ = try OverleafGit.run(["init", "-b", "master"], at: root)
        _ = try OverleafGit.run(["add", "main.tex"], at: root)
        _ = try OverleafGit.run(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "Fixture baseline"], at: root)
        try JSONEncoder().encode([connection]).write(to: folder.appendingPathComponent("projects.json"))
        return (OverleafLibrary(directory: folder), try TeXProject(root, historyEnabled: false), connection)
    }
    let (library, project, connection) = try fixture("live-runtime")
    let channel = LiveFixtureChannel(project: projectID, document: docID, text: base)
    let live = OverleafLiveWorkspace(authenticate: { _ in }, makeChannel: { _ in channel })
    await live.start(project: project, library: library, connection: connection)
    check(live.connected && library.liveOwned.contains(connection.id), "Live workspace owns the project before any Git timer can publish")
    do { _ = try library.writerLease(connection); fatalError("Concurrent Git writer admitted") } catch { }
    await library.check(connection, save: { fatalError("Live ownership allowed Git to save buffers") })
    await library.syncLocalChanges(connection, save: { fatalError("Live ownership allowed automatic Git publication") })
    check(library.review == nil, "Manual and automatic Git paths refuse an actively live project")
    check(live.pendingDocumentCount == 0 && live.lastConfirmedAt != nil, "A joined clean project has server confirmation")
    let firstConfirmation = live.lastConfirmedAt
    await live.flush()
    check(live.lastConfirmedAt == firstConfirmation, "Idle polling does not pretend a new server confirmation occurred")
    await channel.holdSubmissions()
    project.buffers["main.tex"] = prefix + "ALPHA beta gamma\n"
    check(live.pendingDocumentCount == 1, "Typing is pending before the flush timer runs")
    await live.flush()
    check(live.pendingDocumentCount == 1, "An RPC response without applied confirmation stays pending")
    let key = OverleafLive.Key(profile: connection.profileID, project: projectID, document: docID)
    let journal = OverleafLiveJournal.checkpoint(for: key, under: library.directory.appendingPathComponent("Live"))
    check(try OverleafLiveJournal.load(from: journal, for: key).inFlight != nil, "Live workspace persists intent before the server's applied acknowledgement")
    try await channel.remoteEdit(prefix + "alpha beta GAMMA\n")
    project.buffers["main.tex"] = prefix + "ALPHA beta gamma!\n"
    try await channel.release()
    try await until { project.buffers["main.tex"] == prefix + "ALPHA beta GAMMA!\n" || live.issue != nil }
    check(live.issue == nil && project.buffers["main.tex"] == prefix + "ALPHA beta GAMMA!\n", "Server-transformed acknowledgement preserves concurrent remote edits and newer local typing")
    await live.flush()
    try await until { (try? OverleafLiveJournal.load(from: journal, for: key).inFlight) == nil }
    check(await channel.text() == prefix + "ALPHA beta GAMMA!\n", "The next live update publishes only the remaining local intent")
    await live.stop()
    check(!library.liveOwned.contains(connection.id) && library.automaticPaused.contains(connection.id), "Stopping live mode releases ownership but leaves Git publication paused for review")
    do { let lease = try library.writerLease(connection); withExtendedLifetime(lease) {} }

    let (conflictLibrary, conflictProject, conflictConnection) = try fixture("live-conflict")
    conflictProject.buffers["main.tex"] = prefix + "LOCAL beta gamma\n"
    let first = LiveFixtureChannel(project: projectID, document: docID, text: prefix + "REMOTE beta gamma\n")
    let conflicted = OverleafLiveWorkspace(authenticate: { _ in }, makeChannel: { _ in first })
    await conflicted.start(project: conflictProject, library: conflictLibrary, connection: conflictConnection)
    check(conflicted.conflict != nil && conflictProject.buffers["main.tex"] == prefix + "LOCAL beta gamma\n", "Overlapping initial edits preserve the local draft and expose both versions")
    check(try String(contentsOf: conflictProject.root.appendingPathComponent("main.tex"), encoding: .utf8) == base, "A conflicting handshake does not overwrite the existing local file")
    check(await first.submissions == 0, "A conflicting handshake never submits an implicit local-wins update")
    await conflicted.stop()
    let second = LiveFixtureChannel(project: projectID, document: docID, text: prefix + "REMOTE beta gamma\n")
    let third = LiveFixtureChannel(project: projectID, document: docID, text: prefix + "REMOTE beta gamma\n")
    var attempts = 0
    let reopened = OverleafLiveWorkspace(authenticate: { _ in }, makeChannel: { _ in attempts += 1; return attempts == 1 ? second : third })
    await reopened.start(project: conflictProject, library: conflictLibrary, connection: conflictConnection)
    let reopenedSubmissions = await second.submissions
    check(reopened.conflict != nil && reopenedSubmissions == 0, "A persisted conflict still requires review after reopening the live workspace")
    await reopened.choose(false)
    check(reopened.connected && conflictProject.buffers["main.tex"] == prefix + "REMOTE beta gamma\n", "An explicit current remote choice safely resumes the live workspace")
    check(await third.submissions == 0, "Choosing the remote version does not echo it back to the server")
    await reopened.stop()
    let (sectionLibrary, sectionProject, sectionConnection) = try fixture("live-section-choice")
    let localSection = prefix + "LOCAL beta gamma\n"
    sectionProject.buffers["main.tex"] = localSection
    var sectionAttempt = 0
    let sectionFirst = LiveFixtureChannel(project: projectID, document: docID, text: prefix + "REMOTE beta gamma\n")
    let sectionNext = LiveFixtureChannel(project: projectID, document: docID, text: prefix + "REMOTE beta gamma\n")
    let sectionLive = OverleafLiveWorkspace(authenticate: { _ in }, makeChannel: { _ in sectionAttempt += 1; return sectionAttempt == 1 ? sectionFirst : sectionNext })
    await sectionLive.start(project: sectionProject, library: sectionLibrary, connection: sectionConnection)
    await sectionLive.choose(text: prefix + "REVIEWED beta gamma\n")
    check(sectionLive.connected && sectionProject.buffers["main.tex"] == prefix + "REVIEWED beta gamma\n", "An explicit mixed-section result resumes after validating both current versions")
    await sectionLive.stop()

    let (staleLibrary, staleProject, staleConnection) = try fixture("live-stale-choice")
    staleProject.buffers["main.tex"] = localSection
    let staleFirst = LiveFixtureChannel(project: projectID, document: docID, text: prefix + "REMOTE beta gamma\n")
    let staleNext = LiveFixtureChannel(project: projectID, document: docID, text: prefix + "NEWER beta gamma\n")
    var staleAttempt = 0
    let staleLive = OverleafLiveWorkspace(authenticate: { _ in }, makeChannel: { _ in staleAttempt += 1; return staleAttempt == 1 ? staleFirst : staleNext })
    await staleLive.start(project: staleProject, library: staleLibrary, connection: staleConnection)
    await staleLive.choose(text: prefix + "REVIEWED beta gamma\n")
    check(staleLive.conflict != nil && staleProject.buffers["main.tex"] == localSection, "A newer server version invalidates a section choice without replacing the draft")
    check(await staleNext.submissions == 0, "An outdated section choice cannot upload")
    await staleLive.stop()

    let (treeLibrary, treeProject, treeConnection) = try fixture("live-tree-change")
    let treeChannel = LiveFixtureChannel(project: projectID, document: docID, text: base)
    let treeLive = OverleafLiveWorkspace(authenticate: { _ in }, makeChannel: { _ in treeChannel })
    await treeLive.start(project: treeProject, library: treeLibrary, connection: treeConnection)
    await treeChannel.treeChanged()
    try await until { treeLive.requiresGitReview }
    check(treeLive.enabled && !treeLive.connected && treeLibrary.liveOwned.contains(treeConnection.id), "A structure change pauses Live and retains ownership until explicit Git review")
    await treeLive.reviewGit()
    check(!treeLive.enabled && !treeLibrary.liveOwned.contains(treeConnection.id) && treeLibrary.automaticPaused.contains(treeConnection.id), "Git handoff releases Live ownership while keeping automatic publishing paused")
    check(await treeChannel.submissions == 0, "A structure-change handoff never publishes through Live")

    let (lostLibrary, lostProject, lostConnection) = try fixture("live-interrupted")
    let lost = LiveFixtureChannel(project: projectID, document: docID, text: base)
    let fresh = LiveFixtureChannel(project: projectID, document: docID, text: base)
    var reconnects = 0
    let interrupted = OverleafLiveWorkspace(authenticate: { _ in }, makeChannel: { _ in reconnects += 1; return reconnects == 1 ? lost : fresh })
    await interrupted.start(project: lostProject, library: lostLibrary, connection: lostConnection)
    await lost.holdSubmissions()
    let draft = prefix + "Unconfirmed local draft\n"
    lostProject.buffers["main.tex"] = draft
    await interrupted.flush()
    await lost.stop()
    try await until { interrupted.issue != nil }
    check(!interrupted.connected && interrupted.enabled && interrupted.pendingDocumentCount == 1, "A closed event stream pauses Live and retains pending intent")
    check(lostLibrary.liveOwned.contains(lostConnection.id), "A lost connection cannot enable competing Git publication")
    await interrupted.retry()
    check(interrupted.conflict != nil && lostProject.buffers["main.tex"] == draft, "Reconnect preserves an uncertain upload for explicit review")
    check(await fresh.submissions == 0, "Reconnect never blindly replays uncertain intent")
    await interrupted.stop()

    let (lockedLibrary, _, lockedConnection) = try fixture("git-locked-account")
    do { _ = try OverleafCredential.read(lockedConnection.profileID) } catch { }
    check(OverleafCredential.locked(lockedConnection.profileID), "A missing non-interactive credential marks only its account as locked")
    await lockedLibrary.syncLocalChanges(lockedConnection, save: { fatalError("Locked automatic sync attempted to save or use Git") })
    check(!lockedLibrary.busy && lockedLibrary.error == nil, "A locked automatic connection waits for explicit unlock without repeated error dialogs")

    let (multiLibrary, initialMultiProject, multiConnection) = try fixture("live-multiple")
    try base.write(to: initialMultiProject.root.appendingPathComponent("second.tex"), atomically: true, encoding: .utf8)
    _ = try OverleafGit.run(["add", "second.tex"], at: initialMultiProject.root)
    _ = try OverleafGit.run(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "Second fixture"], at: initialMultiProject.root)
    let multiProject = try TeXProject(initialMultiProject.root, historyEnabled: false)
    let multiChannel = MultiLiveFixtureChannel(project: projectID, text: base)
    let multiLive = OverleafLiveWorkspace(authenticate: { _ in }, makeChannel: { _ in multiChannel })
    await multiLive.start(project: multiProject, library: multiLibrary, connection: multiConnection)
    check(multiLive.connected && multiLive.issue == nil, "Multi-document fixture joins both existing project files")
    let beforeUploads = multiLive.lastConfirmedAt
    multiProject.buffers["main.tex"] = base + "% first\n"
    multiProject.buffers["second.tex"] = base + "% second\n"
    await multiLive.flush()
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while await multiChannel.pendingCount < 2 {
        precondition(ContinuousClock.now < deadline, "Both fixture uploads must reach the held transport")
        try await Task.sleep(for: .milliseconds(20))
    }
    check(multiLive.pendingDocumentCount == 2, "Pending status counts the whole project")
    await multiChannel.confirm("000000000000000000000001")
    try await until { multiLive.pendingDocumentCount == 1 }
    check(multiLive.lastConfirmedAt == beforeUploads, "One acknowledged file cannot confirm another pending document")
    await multiChannel.confirm("000000000000000000000002")
    try await until { multiLive.pendingDocumentCount == 0 && multiLive.lastConfirmedAt != beforeUploads }
    check(multiLive.lastConfirmedAt != nil, "Project confirmation advances only after every pending file is confirmed")
    await multiLive.stop()

    let (authLibrary, authProject, authConnection) = try fixture("live-auth-pauses")
    for (failure, reason) in [(OverleafWebClient.Failure.sessionLocked, "Connection locked"), (.signIn, "Sign in required"), (.permission, "Access not permitted")] {
        let blocked = OverleafLiveWorkspace(authenticate: { _ in throw failure }, makeChannel: { _ in fatalError("An unauthenticated session must not open a socket") })
        await blocked.start(project: authProject, library: authLibrary, connection: authConnection)
        check(!blocked.connected && blocked.pauseReason == reason, "Authentication and access failures give the correct persistent pause reason")
        await blocked.stop()
    }

}
