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
    func remoteComment(offset: Int, text: String) {
        let version = remote.version; remote = .init(version: version + 1, text: remote.text)
        output.yield(.init(name: "otUpdateApplied", args: [.object(["doc": .string(documentID), "v": .int(version), "op": .array([.object(["p": .int(offset), "c": .string(text)])])])]))
    }
    func remoteNoop() {
        let version = remote.version; remote = .init(version: version + 1, text: remote.text)
        output.yield(.init(name: "otUpdateApplied", args: [.object(["doc": .string(documentID), "v": .int(version), "op": .array([])])]))
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
    let live = OverleafLiveWorkspace(syncFiles: false, authenticate: { _ in }, makeChannel: { _ in channel })
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
    let sourceURL = project.root.appendingPathComponent("main.tex")
    let beforeComment = try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.systemFileNumber] as? NSNumber
    await channel.remoteComment(offset: prefix.utf16.count, text: "alpha")
    try await Task.sleep(for: .milliseconds(100))
    check(live.connected && live.issue == nil && project.buffers["main.tex"] == base, "A collaborator comment stays connected without changing source text")
    check(try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.systemFileNumber] as? NSNumber == beforeComment, "Comment-only acknowledgement does not replace the unchanged source file")
    check(live.automationStatus["confirmed"] as? Bool == true, "CLI reports confirmed Live observations for clean source")
    await channel.holdSubmissions()
    project.buffers["main.tex"] = prefix + "ALPHA beta gamma\n"
    check(live.pendingDocumentCount == 1, "Typing is pending before the flush timer runs")
    check(live.automationStatus["confirmed"] as? Bool == false && live.automationStatus["pendingDocuments"] as? Int == 1, "CLI distinguishes unflushed typing from remote confirmation")
    await live.flush()
    check(live.pendingDocumentCount == 1, "An RPC response without applied confirmation stays pending")
    await channel.remoteNoop()
    try await Task.sleep(for: .milliseconds(100))
    check(live.pendingDocumentCount == 1 && project.buffers["main.tex"] == prefix + "ALPHA beta gamma\n", "A remote empty operation is not mistaken for our pending upload's ACK")
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
    check(live.pendingDocumentCount == 0 && live.lastConfirmedAt == nil && project.buffers["main.tex"] == prefix + "ALPHA beta GAMMA!\n", "Stopping clears session caches and confirmation without discarding the editor source")
    check(!library.liveOwned.contains(connection.id) && library.automaticPaused.contains(connection.id), "Stopping live mode releases ownership but leaves Git publication paused for review")
    do { let lease = try library.writerLease(connection); withExtendedLifetime(lease) {} }

    let (conflictLibrary, conflictProject, conflictConnection) = try fixture("live-conflict")
    conflictProject.buffers["main.tex"] = prefix + "LOCAL beta gamma\n"
    let first = LiveFixtureChannel(project: projectID, document: docID, text: prefix + "REMOTE beta gamma\n")
    let conflicted = OverleafLiveWorkspace(syncFiles: false, authenticate: { _ in }, makeChannel: { _ in first })
    await conflicted.start(project: conflictProject, library: conflictLibrary, connection: conflictConnection)
    check(conflicted.conflict != nil && conflictProject.buffers["main.tex"] == prefix + "LOCAL beta gamma\n", "Overlapping initial edits preserve the local draft and expose both versions")
    check(try String(contentsOf: conflictProject.root.appendingPathComponent("main.tex"), encoding: .utf8) == base, "A conflicting handshake does not overwrite the existing local file")
    check(await first.submissions == 0, "A conflicting handshake never submits an implicit local-wins update")
    await conflicted.stop()
    let second = LiveFixtureChannel(project: projectID, document: docID, text: prefix + "REMOTE beta gamma\n")
    let third = LiveFixtureChannel(project: projectID, document: docID, text: prefix + "REMOTE beta gamma\n")
    var attempts = 0
    let reopened = OverleafLiveWorkspace(syncFiles: false, authenticate: { _ in }, makeChannel: { _ in attempts += 1; return attempts == 1 ? second : third })
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
    let sectionLive = OverleafLiveWorkspace(syncFiles: false, authenticate: { _ in }, makeChannel: { _ in sectionAttempt += 1; return sectionAttempt == 1 ? sectionFirst : sectionNext })
    await sectionLive.start(project: sectionProject, library: sectionLibrary, connection: sectionConnection)
    await sectionLive.choose(text: prefix + "REVIEWED beta gamma\n")
    check(sectionLive.connected && sectionProject.buffers["main.tex"] == prefix + "REVIEWED beta gamma\n", "An explicit mixed-section result resumes after validating both current versions")
    await sectionLive.stop()

    let (staleLibrary, staleProject, staleConnection) = try fixture("live-stale-choice")
    staleProject.buffers["main.tex"] = localSection
    let staleFirst = LiveFixtureChannel(project: projectID, document: docID, text: prefix + "REMOTE beta gamma\n")
    let staleNext = LiveFixtureChannel(project: projectID, document: docID, text: prefix + "NEWER beta gamma\n")
    var staleAttempt = 0
    let staleLive = OverleafLiveWorkspace(syncFiles: false, authenticate: { _ in }, makeChannel: { _ in staleAttempt += 1; return staleAttempt == 1 ? staleFirst : staleNext })
    await staleLive.start(project: staleProject, library: staleLibrary, connection: staleConnection)
    await staleLive.choose(text: prefix + "REVIEWED beta gamma\n")
    check(staleLive.conflict != nil && staleProject.buffers["main.tex"] == localSection, "A newer server version invalidates a section choice without replacing the draft")
    check(await staleNext.submissions == 0, "An outdated section choice cannot upload")
    await staleLive.stop()

    let (treeLibrary, treeProject, treeConnection) = try fixture("live-tree-change")
    let treeChannel = LiveFixtureChannel(project: projectID, document: docID, text: base)
    let treeLive = OverleafLiveWorkspace(syncFiles: false, authenticate: { _ in }, makeChannel: { _ in treeChannel })
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
    let interrupted = OverleafLiveWorkspace(syncFiles: false, authenticate: { _ in }, makeChannel: { _ in reconnects += 1; return reconnects == 1 ? lost : fresh })
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

    try await checkAutomaticRecovery(fixture: fixture, base: base, prefix: prefix, check: check)

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
    let multiLive = OverleafLiveWorkspace(syncFiles: false, authenticate: { _ in }, makeChannel: { _ in multiChannel })
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
        let blocked = OverleafLiveWorkspace(syncFiles: false, authenticate: { _ in throw failure }, makeChannel: { _ in fatalError("An unauthenticated session must not open a socket") })
        await blocked.start(project: authProject, library: authLibrary, connection: authConnection)
        check(!blocked.connected && blocked.pauseReason == reason, "Authentication and access failures give the correct persistent pause reason")
        await blocked.stop()
    }

}

@MainActor func checkReviewDecisions(output: URL, check: @escaping (Bool, String) -> Void) async throws {
    let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    var online = original; online[NetworkAccessGate.preference] = false
    UserDefaults.standard.setVolatileDomain(online, forName: UserDefaults.argumentDomain)
    defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
    let folder = output.appendingPathComponent("review-decisions")
    let connection = OverleafConnection(id: UUID(), profileID: UUID(), projectID: "6ad72e207e5cd74f01fe6b18", name: "Review fixture", account: "Fixture", branch: "master")
    let document = "6ad72e207e5cd74f01fe6b19", source = "\\documentclass{article}\nalpha beta\n"
    let root = folder.appendingPathComponent("Projects/" + connection.id.uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try source.write(to: root.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
    _ = try OverleafGit.run(["init", "-b", "master"], at: root)
    _ = try OverleafGit.run(["add", "main.tex"], at: root)
    _ = try OverleafGit.run(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "Fixture baseline"], at: root)
    try JSONEncoder().encode([connection]).write(to: folder.appendingPathComponent("projects.json"))
    let library = OverleafLibrary(directory: folder), project = try TeXProject(root, historyEnabled: false)
    let channel = LiveFixtureChannel(project: connection.projectID, document: document, text: source)
    var currentID: String? = "accept-me", accepted: [String] = []
    let offset = (source as NSString).range(of: "alpha").location
    func change(_ id: String) -> OverleafReviewSnapshot.Change {
        .init(id: document + ":" + id, documentID: document, changeID: id, insertion: true, text: "alpha", anchor: .init(file: "main.tex", source: source, version: 1, offset: offset, length: 5), timestamp: nil)
    }
    let live = OverleafLiveWorkspace(syncFiles: false, authenticate: { _ in }, makeChannel: { _ in channel }, readReviewRanges: { _ in
        let text = await channel.text()
        guard let id = currentID, text == source else { return Data("[]".utf8) }
        return try JSONSerialization.data(withJSONObject: [["id": document, "ranges": ["changes": [["id": id, "op": ["p": offset, "i": "alpha"]]]]]])
    }, acceptReviewChange: { _, doc, id in
        check(doc == document, "Acceptance addresses the verified document")
        accepted.append(id); currentID = nil
    })
    project.editSource = { path, before, after, _ in
        guard project.buffers[path] == before else { return false }
        project.buffers[path] = after
        return true
    }
    await live.start(project: project, library: library, connection: connection)
    check(live.connected, "Review fixture uses the existing Live writer")
    try await live.decideReviewChange(change("accept-me"), accept: true)
    check(accepted == ["accept-me"] && project.buffers["main.tex"] == source, "Accept clears only the selected range and leaves source unchanged")
    do { try await live.decideReviewChange(change("accept-me"), accept: true); fatalError("Stale range accepted twice") } catch { }
    check(accepted.count == 1, "A disappeared change cannot be accepted again")
    currentID = "reject-me"
    project.buffers["main.tex"] = source + "new typing"
    do { try await live.decideReviewChange(change("reject-me"), accept: false); fatalError("Unconfirmed source overwritten") } catch { }
    check(project.buffers["main.tex"] == source + "new typing", "Unconfirmed local edits block rejection without losing text")
    project.buffers["main.tex"] = source
    try await live.decideReviewChange(change("reject-me"), accept: false)
    check(project.buffers["main.tex"] == source.replacingOccurrences(of: "alpha", with: ""), "Reject restores source through the Live acknowledgement path")
    check(accepted == ["accept-me"], "Reject never substitutes a metadata acceptance request")
    live.setVisible(false)
    let warmConfirmation = live.lastConfirmedAt
    live.setVisible(true)
    live.connectVisible(project: project, library: library, connection: connection)
    check(live.connected && !live.connecting && live.lastConfirmedAt == warmConfirmation, "Returning to a visible project reuses its confirmed connection")
    await live.stop()
    do { try await live.decideReviewChange(change("reject-me"), accept: false); fatalError("Stopped writer accepted a review action") } catch { }
    project.editSource = nil
    check(true, "Stopped Live writers refuse review mutations")
}

@MainActor func checkWarmProject(output: URL, check: (Bool, String) -> Void) async throws {
    let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    var online = original; online[NetworkAccessGate.preference] = false
    UserDefaults.standard.setVolatileDomain(online, forName: UserDefaults.argumentDomain)
    defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
    let folder = output.appendingPathComponent("warm-project")
    let connection = OverleafConnection(id: UUID(), profileID: UUID(), projectID: "6ad72e207e5cd74f01fe6b18", name: "Warm fixture", account: "Fixture", branch: "master")
    let root = folder.appendingPathComponent("Projects/" + connection.id.uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "\\documentclass{article}\n".write(to: root.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
    _ = try OverleafGit.run(["init", "-b", "master"], at: root)
    _ = try OverleafGit.run(["add", "main.tex"], at: root)
    _ = try OverleafGit.run(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "Fixture baseline"], at: root)
    try JSONEncoder().encode([connection]).write(to: folder.appendingPathComponent("projects.json"))
    let library = OverleafLibrary(directory: folder), project = try TeXProject(root, historyEnabled: false)
    let channel = LiveFixtureChannel(project: connection.projectID, document: "6ad72e207e5cd74f01fe6b19", text: project.buffers["main.tex"]!)
    project.liveWorkspace = OverleafLiveWorkspace(syncFiles: false, authenticate: { _ in }, makeChannel: { _ in channel })
    await project.liveWorkspace.start(project: project, library: library, connection: connection)
    check(project.liveWorkspace.connected, "Warm fixture starts with confirmed Live sync")
    check(library.retainWarmProject(project), "A closed Live project can stay warm briefly")
    let controller = project.sourceEditor
    _ = controller.makeView()
    controller.update(project.buffers["main.tex"]!, size: 17, serif: false, document: "main.tex")
    controller.textView?.setSelectedRange(NSRange(location: 4, length: 0))
    check(library.takeWarmProject(root) === project && project.liveWorkspace.connected && project.sourceEditor === controller && controller.textView?.selectedRange().location == 4, "A quick return keeps the same editor, PDF and socket owner")
    check(library.retainWarmProject(project, duration: .milliseconds(30)), "The warm project has a bounded lifetime")
    try await Task.sleep(for: .milliseconds(100))
    check(library.warmProject == nil && !project.liveWorkspace.enabled, "Warm expiry closes the socket and releases retained resources")
}

// A shared fake server survives socket replacement and models ShareJS source deduplication.
actor RecoveryFixtureServer {
    private var snapshots: [OverleafLive.Snapshot]
    private var operations: [OverleafLiveWire.JSON] = []
    private var late: (OverleafLive.Submission, String)?
    private(set) var applied = 0
    init(_ text: String) { snapshots = [.init(version: 1, text: text)] }
    func snapshot() -> OverleafLive.Snapshot { snapshots.last! }
    func scheduleLate(_ op: OverleafLive.Submission, source: String) { late = (op, source) }
    func catchUp(_ version: Int) throws -> OverleafLiveWire.CatchUp {
        let result = OverleafLiveWire.CatchUp(snapshot: snapshot(), operations: Array(operations.dropFirst(version - 1)))
        if let late { self.late = nil; _ = try apply(late.0, source: late.1) }
        return result
    }
    func apply(_ op: OverleafLive.Submission, source: String) throws -> Int {
        if let prior = operations.first(where: { ($0["v"].integer ?? 0) >= op.baseVersion && op.sources?.contains($0["meta"]["source"].string ?? "") == true }) { return prior["v"].integer! }
        let current = snapshot(), original = snapshots[op.baseVersion - 1]
        let text = try OverleafLiveText.merge(base: original.text, local: op.after, remote: current.text)
        let edit = try OverleafLive.Edit.between(current.text, text)
        let actual = OverleafLive.Submission(id: op.id, epoch: op.epoch, key: op.key, baseVersion: current.version, edit: edit, after: text)
        var wire = OverleafLiveWire.update(actual)
        if case .object(var fields) = wire { fields["meta"] = .object(["source": .string(source)]); wire = .object(fields) }
        operations.append(wire); snapshots.append(.init(version: current.version + 1, text: text)); applied += 1
        return current.version
    }
    func remoteEdit(_ text: String, key: OverleafLive.Key) throws {
        let old = snapshot(), edit = try OverleafLive.Edit.between(old.text, text)
        _ = try apply(.init(id: UUID(), epoch: UUID(), key: key, baseVersion: old.version, edit: edit, after: text), source: "browser-collaborator")
    }
}
actor RecoveryFixtureChannel: OverleafLiveChannel {
    enum Drop { case none, beforeApply, afterApply, lateApply }
    nonisolated let events: AsyncStream<OverleafLiveSocket.Event>
    private let output: AsyncStream<OverleafLiveSocket.Event>.Continuation
    let server: RecoveryFixtureServer
    let source: String
    let project: String
    let document: String
    var drop: Drop
    let connectionFailure: Bool
    private(set) var submissions = 0
    init(server: RecoveryFixtureServer, source: String, project: String, document: String, drop: Drop = .none, connectionFailure: Bool = false) {
        self.server = server; self.source = source; self.project = project; self.document = document; self.drop = drop; self.connectionFailure = connectionFailure
        let stream = AsyncStream<OverleafLiveSocket.Event>.makeStream(); events = stream.stream; output = stream.continuation
    }
    func sourceID() -> String? { source }
    func connect() throws -> OverleafLiveWire.JSON {
        if connectionFailure { throw URLError(.networkConnectionLost) }
        return .object(["_id": .string(project), "rootFolder": .array([.object(["docs": .array([.object(["_id": .string(document), "name": .string("main.tex")])])])])])
    }
    func join(_ doc: String) async -> OverleafLive.Snapshot { await server.snapshot() }
    func catchUp(_ doc: String, version: Int) async throws -> OverleafLiveWire.CatchUp? { try await server.catchUp(version) }
    func leave(_ doc: String) {}
    func submit(_ op: OverleafLive.Submission) async throws {
        submissions += 1
        if drop == .beforeApply { drop = .none; throw URLError(.networkConnectionLost) }
        if drop == .lateApply { drop = .none; await server.scheduleLate(op, source: source); throw URLError(.networkConnectionLost) }
        let version = try await server.apply(op, source: source)
        if drop == .afterApply { drop = .none; throw URLError(.networkConnectionLost) }
        output.yield(.init(name: "otUpdateApplied", args: [.object(["doc": .string(document), "v": .int(version)])]))
    }
    func disconnect(_ error: Error = URLError(.networkConnectionLost)) { output.yield(.init(name: "remileDisconnected", args: [], failure: error)); output.finish() }
    func stop() { output.finish() }
}

@MainActor func checkAutomaticRecovery(fixture: (String) throws -> (OverleafLibrary, TeXProject, OverleafConnection), base: String, prefix: String, check: (Bool, String) -> Void) async throws {
    let projectID = "6ad72e207e5cd74f01fe6b18", docID = "6ad72e207e5cd74f01fe6b19"
    for (name, drop) in [("unsent", RecoveryFixtureChannel.Drop.beforeApply), ("applied-ack-lost", .afterApply), ("late-original", .lateApply)] {
        let (library, project, connection) = try fixture("recovery-" + name)
        let server = RecoveryFixtureServer(base)
        let first = RecoveryFixtureChannel(server: server, source: "first", project: projectID, document: docID, drop: drop)
        let second = RecoveryFixtureChannel(server: server, source: "second", project: projectID, document: docID)
        var attempts = 0
        let live = OverleafLiveWorkspace(syncFiles: false, retryDelay: { _ in .milliseconds(80) }, authenticate: { _ in }, makeChannel: { _ in attempts += 1; return attempts == 1 ? first : second })
        await live.start(project: project, library: library, connection: connection)
        let draft = prefix + "ALPHA beta gamma\n"
        project.buffers["main.tex"] = draft; await live.flush()
        check(live.reconnecting && !live.connected, name + ": interruption enters automatic recovery")
        project.buffers["main.tex"] = draft + "% New typing while offline\n"
        try await until { live.connected && live.pendingDocumentCount == 0 }
        check(await server.snapshot().text == project.buffers["main.tex"] && live.conflict == nil, name + ": recovery keeps new typing without a Sync action")
        check(await server.applied == 2, name + ": original intent and newer typing are each applied exactly once")
        await live.stop()
    }
    let (library, project, connection) = try fixture("recovery-undo")
    let server = RecoveryFixtureServer(base)
    let first = RecoveryFixtureChannel(server: server, source: "undo-first", project: projectID, document: docID, drop: .lateApply)
    let second = RecoveryFixtureChannel(server: server, source: "undo-second", project: projectID, document: docID)
    var attempts = 0
    let live = OverleafLiveWorkspace(syncFiles: false, retryDelay: { _ in .milliseconds(80) }, authenticate: { _ in }, makeChannel: { _ in attempts += 1; return attempts == 1 ? first : second })
    await live.start(project: project, library: library, connection: connection)
    project.buffers["main.tex"] = prefix + "ALPHA beta gamma\n"; await live.flush()
    project.buffers["main.tex"] = base
    try await until { live.connected && live.pendingDocumentCount == 0 }
    check(await server.snapshot().text == base && project.buffers["main.tex"] == base, "An Undo during outage is not lost when the old upload arrives late")
    await live.stop()

    let (collabLibrary, collabProject, collabConnection) = try fixture("recovery-collaborator")
    let collabServer = RecoveryFixtureServer(base)
    let collabFirst = RecoveryFixtureChannel(server: collabServer, source: "collab-first", project: projectID, document: docID, drop: .afterApply)
    var collabAttempts = 0
    let collab = OverleafLiveWorkspace(syncFiles: false, retryDelay: { _ in .milliseconds(120) }, authenticate: { _ in }, makeChannel: { _ in collabAttempts += 1; return collabAttempts == 1 ? collabFirst : RecoveryFixtureChannel(server: collabServer, source: "collab-next", project: projectID, document: docID) })
    await collab.start(project: collabProject, library: collabLibrary, connection: collabConnection)
    collabProject.buffers["main.tex"] = prefix + "ALPHA beta gamma\n"; await collab.flush()
    try await collabServer.remoteEdit(prefix + "ALPHA beta GAMMA\n", key: .init(profile: collabConnection.profileID, project: projectID, document: docID))
    collabProject.buffers["main.tex"]! += "% Further local typing\n"
    try await until { collab.connected && collab.pendingDocumentCount == 0 }
    check(await collabServer.snapshot().text == prefix + "ALPHA beta GAMMA\n% Further local typing\n" && collab.conflict == nil, "Server history recovers an applied edit alongside a collaborator's disjoint change")
    await collab.stop()

    let (retryLibrary, retryProject, retryConnection) = try fixture("recovery-brief-outage")
    let retryServer = RecoveryFixtureServer(base)
    let retryFirst = RecoveryFixtureChannel(server: retryServer, source: "outage-first", project: projectID, document: docID)
    var retryAttempts = 0
    let retrying = OverleafLiveWorkspace(syncFiles: false, retryDelay: { _ in .milliseconds(40) }, authenticate: { _ in }, makeChannel: { _ in
        retryAttempts += 1
        return retryAttempts == 1 ? retryFirst : RecoveryFixtureChannel(server: retryServer, source: "outage-\(retryAttempts)", project: projectID, document: docID, connectionFailure: retryAttempts < 4)
    })
    await retrying.start(project: retryProject, library: retryLibrary, connection: retryConnection)
    await retryFirst.disconnect()
    try await until { retrying.reconnecting }
    retryProject.buffers["main.tex"] = prefix + "ALPHA beta gamma\n"
    try await retryServer.remoteEdit(prefix + "alpha beta GAMMA\n", key: .init(profile: retryConnection.profileID, project: projectID, document: docID))
    try await until { retrying.connected && retrying.pendingDocumentCount == 0 }
    check(retryAttempts == 4 && retryProject.buffers["main.tex"] == prefix + "ALPHA beta GAMMA\n", "A brief outage and repeated transport failures recover automatically with disjoint browser edits")
    await retrying.stop()

    let (offlineLibrary, offlineProject, offlineConnection) = try fixture("recovery-explicit-offline")
    let offlineServer = RecoveryFixtureServer(base)
    var offlineAttempts = 0
    let offline = OverleafLiveWorkspace(syncFiles: false, retryDelay: { _ in .milliseconds(30) }, authenticate: { _ in }, makeChannel: { _ in offlineAttempts += 1; return RecoveryFixtureChannel(server: offlineServer, source: "offline-\(offlineAttempts)", project: projectID, document: docID) })
    await offline.start(project: offlineProject, library: offlineLibrary, connection: offlineConnection)
    offlineLibrary.offlineMode = true; await offline.networkChanged()
    offlineProject.buffers["main.tex"] = prefix + "Saved while offline\n"
    try await Task.sleep(for: .milliseconds(120))
    check(offlineAttempts == 1 && !offline.connected, "Work offline suppresses reconnection attempts")
    offlineLibrary.offlineMode = false; await offline.networkChanged()
    try await until { offline.connected && offline.pendingDocumentCount == 0 }
    check(await offlineServer.snapshot().text == offlineProject.buffers["main.tex"], "Going online automatically shares the preserved draft")
    await offline.stop(); await offline.networkChanged()
    try await Task.sleep(for: .milliseconds(80))
    check(!offline.enabled && offlineAttempts == 2, "An explicit stop cannot be undone by network recovery")

    let (fatalLibrary, fatalProject, fatalConnection) = try fixture("recovery-permission")
    let fatalServer = RecoveryFixtureServer(base), fatalChannel = RecoveryFixtureChannel(server: RecoveryFixtureServer(base), source: "fatal", project: projectID, document: docID)
    var fatalAttempts = 0
    let fatal = OverleafLiveWorkspace(syncFiles: false, retryDelay: { _ in .milliseconds(20) }, authenticate: { _ in }, makeChannel: { _ in fatalAttempts += 1; return fatalAttempts == 1 ? fatalChannel : RecoveryFixtureChannel(server: fatalServer, source: "unexpected", project: projectID, document: docID) })
    await fatal.start(project: fatalProject, library: fatalLibrary, connection: fatalConnection)
    await fatalChannel.disconnect(OverleafLiveWire.Failure.permission)
    try await until { fatal.issue != nil }
    try await Task.sleep(for: .milliseconds(100))
    check(!fatal.reconnecting && fatalAttempts == 1, "A typed permission failure never becomes an automatic reconnect loop")
    await fatal.stop()
}
