import Foundation

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}
func check(_ value: Bool, _ name: String) { precondition(value, name); print("PASS: " + name) }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
func bytes(_ text: String) -> Data { Data(text.utf8) }
@MainActor final class FileRemoteFixture: OverleafFileRemote {
    var files: [String: Data]
    var entries: [String: OverleafLiveFiles.Entry]
    var next = 10
    var operations: [String] = []
    var loseUpload = false
    var racePark = false
    var onSnapshot: (() -> Void)?
    init(_ files: [String: Data]) {
        self.files = files; entries = [:]
        for (index, path) in files.keys.sorted().enumerated() { entries[path] = .init(id: String(format: "%024x", index + 1), kind: OverleafLiveFiles.source(path) ? "doc" : "file", path: path) }
    }
    var tree: OverleafLiveFiles.Tree { .init(files: entries, folders: ["": String(repeating: "f", count: 24)]) }
    func snapshot(_ advertised: OverleafLiveFiles.Tree?) async throws -> OverleafFileSnapshot {
        if let advertised { precondition(advertised == tree) }
        onSnapshot?(); onSnapshot = nil
        return .init(tree: tree, files: files)
    }
    func upload(_ bytes: Data, path: String, root: String) async throws -> OverleafLiveFiles.Entry {
        precondition(files[path] == nil, "Never overwrite an existing visible name on upload")
        next += 1
        let entry = OverleafLiveFiles.Entry(id: String(format: "%024x", next), kind: OverleafLiveFiles.source(path) ? "doc" : "file", path: path)
        entries[path] = entry; files[path] = bytes; operations.append("upload:" + path)
        if loseUpload { throw OverleafLiveFiles.Failure.uncertain }
        return entry
    }
    func rename(_ entry: OverleafLiveFiles.Entry, name: String) throws {
        let path = entries.first { $0.value.id == entry.id }!.key
        let parent = (path as NSString).deletingLastPathComponent
        let target = parent.isEmpty ? name : parent + "/" + name
        guard files[target] == nil else { throw OverleafLiveFiles.Failure.stale }
        files[target] = files.removeValue(forKey: path); entries[path] = nil
        entries[target] = .init(id: entry.id, kind: entry.kind, path: target); operations.append("rename:" + path)
        if racePark && name.hasPrefix("remile-recovery-") { files[target] = bytes("racing edit") }
    }
    func delete(_ entry: OverleafLiveFiles.Entry) throws {
        guard entries[entry.path]?.id == entry.id else { throw OverleafLiveFiles.Failure.stale }
        files[entry.path] = nil; entries[entry.path] = nil; operations.append("delete:" + entry.path)
    }
    func close() { }
}
actor FileLiveFixtureChannel: OverleafLiveChannel {
    nonisolated let events: AsyncStream<OverleafLiveSocket.Event>
    private let output: AsyncStream<OverleafLiveSocket.Event>.Continuation
    private let remote: FileRemoteFixture
    private let project: String
    init(remote: FileRemoteFixture, project: String) {
        self.remote = remote; self.project = project
        let stream = AsyncStream<OverleafLiveSocket.Event>.makeStream(); events = stream.stream; output = stream.continuation
    }
    func connect() async -> OverleafLiveWire.JSON {
        let tree = await remote.tree
        return .object(["_id": .string(project), "rootFolder": .array([.object(["_id": .string(tree.folders[""]!), "docs": .array(tree.files.values.filter { $0.kind == "doc" }.map { .object(["_id": .string($0.id), "name": .string($0.path)]) }), "fileRefs": .array(tree.files.values.filter { $0.kind == "file" }.map { .object(["_id": .string($0.id), "name": .string($0.path)]) })])])])
    }
    func join(_ document: String) async throws -> OverleafLive.Snapshot {
        let tree = await remote.tree, files = await remote.files
        guard let entry = tree.files.values.first(where: { $0.id == document }), let data = files[entry.path], let text = String(data: data, encoding: .utf8) else { throw OverleafLiveFiles.Failure.stale }
        return .init(version: 1, text: text)
    }
    func leave(_ document: String) { }
    func submit(_ operation: OverleafLive.Submission) throws { throw OverleafLiveWire.Failure.protocolMismatch }
    func stop() { output.finish() }
    func changed() { output.yield(.init(name: "reciveNewFile", args: [])) }
}
@MainActor func eventually(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !(await condition()) { guard ContinuousClock.now < deadline else { throw OverleafLiveWire.Failure.timeout }; try await Task.sleep(for: .milliseconds(20)) }
}
Task { @MainActor in
    do {
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var online = original; online[NetworkAccessGate.preference] = false
        UserDefaults.standard.setVolatileDomain(online, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        let main = bytes("\\documentclass{article}\n\\begin{document}hello\\end{document}\n")
        let base = ["main.tex": main, "figure.png": bytes("old image"), "old.tex": bytes("old source")]
        var local = base; local["new.tex"] = bytes("new source"); local["old.tex"] = nil; local["figure.png"] = bytes("new image")
        var remote = base; remote["server.png"] = bytes("server image")
        let plan = try OverleafLiveFiles.plan(base: base, local: local, remote: remote, joinedText: ["main.tex"])
        check(plan.uploads == ["figure.png", "new.tex"] && plan.deletions == ["old.tex"] && plan.downloads == ["server.png"], "Plan combines independent local and remote additions, deletion and image replacement")
        var changed = remote; changed["figure.png"] = bytes("other image")
        do { _ = try OverleafLiveFiles.plan(base: base, local: local, remote: changed, joinedText: []); fatalError("Conflict ignored") } catch { check(true, "Concurrent binary replacement needs review") }
        changed = base; changed["old.tex"] = bytes("remote edit")
        do { _ = try OverleafLiveFiles.plan(base: base, local: local, remote: changed, joinedText: []); fatalError("Delete/edit ignored") } catch { check(true, "Delete versus remote text edit needs review") }
        for bad in ["../x", "/x", "a/../b", ".git/config", "a/.env", "a\\b", "a//b", "a\u{0}b"] { check(!OverleafLiveFiles.validPath(bad), "Reject unsafe path " + bad.debugDescription) }
        let encodedTree: OverleafLiveWire.JSON = .object(["_id": .string(String(repeating: "a", count: 24)), "rootFolder": .array([.object(["_id": .string(String(repeating: "b", count: 24)), "docs": .array([.object(["_id": .string(String(repeating: "c", count: 24)), "name": .string("main.tex")])]), "fileRefs": .array([.object(["_id": .string(String(repeating: "d", count: 24)), "name": .string("figure.png")])])])])])
        let decoded = try OverleafLiveFiles.tree(encodedTree, project: String(repeating: "a", count: 24))
        check(decoded.files["main.tex"]?.kind == "doc" && decoded.files["figure.png"]?.kind == "file", "Decode document and image identities separately")
        let run = output.appendingPathComponent(UUID().uuidString)
        let library = OverleafLibrary(directory: run.appendingPathComponent("library"))
        let account = library.saveAccount(name: "Fixture", token: "", plan: .free)!
        var connection = OverleafConnection(id: UUID(), profileID: account.id, projectID: String(repeating: "a", count: 24), name: "Fixture", account: account.name, branch: "master"); connection.liveOnly = true
        let root = library.root(connection); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, data) in local { try data.write(to: root.appendingPathComponent(path)) }
        let linked = root.appendingPathComponent("figure.png")
        try FileManager.default.removeItem(at: linked)
        let linkTarget = run.appendingPathComponent("linked-image.png"); try bytes("linked image").write(to: linkTarget)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: linkTarget)
        do { _ = try OverleafLiveFiles.scan(root); fatalError("A symlink became a remote deletion") }
        catch { check(true, "A local symlink stops the snapshot instead of becoming a remote deletion") }
        try FileManager.default.removeItem(at: linked); try local["figure.png"]!.write(to: linked)
        do { _ = try OverleafLiveFiles.scan(run.appendingPathComponent("missing-project")); fatalError("An unavailable root became an empty snapshot") }
        catch { check(true, "An unavailable project root cannot become an empty deletion snapshot") }
        let expectedAssetHash = OverleafLiveFiles.fingerprint(try OverleafLiveFiles.scan(root), assetsOnly: true)
        check(try OverleafLiveFiles.fingerprintAssets(at: root) == expectedAssetHash, "Streaming assets preserve the exact existing fingerprint")
        let largeAsset = root.appendingPathComponent("streaming.bin")
        try Data(repeating: 173, count: 2 * 1024 * 1024 + 17).write(to: largeAsset)
        check(try OverleafLiveFiles.fingerprintAssets(at: root) == OverleafLiveFiles.fingerprint(OverleafLiveFiles.scan(root), assetsOnly: true), "Multi-chunk hashing matches across chunk boundaries")
        try FileManager.default.removeItem(at: largeAsset)
        let sourceURL = root.appendingPathComponent("main.tex")
        let savedSource = try Data(contentsOf: sourceURL)
        try bytes("changed text").write(to: sourceURL)
        check(try OverleafLiveFiles.fingerprintAssets(at: root) == expectedAssetHash, "Text edits do not trigger binary reconciliation")
        try savedSource.write(to: sourceURL)
        try FileManager.default.createSymbolicLink(at: largeAsset, withDestinationURL: linkTarget)
        do { _ = try OverleafLiveFiles.fingerprintAssets(at: root); fatalError("Streaming scan followed a symlink") }
        catch { check(true, "Streaming inspection keeps the symlink safety boundary") }
        try FileManager.default.removeItem(at: largeAsset)
        let project = try TeXProject(root, historyEnabled: false)
        try OverleafLiveFiles.save(base, to: OverleafFileSync.baseline(connection, library: library.directory))
        let service = FileRemoteFixture(remote), sync = OverleafFileSync(makeRemote: { _ in service })
        project.compiling = true
        var finished = false
        let pendingReconcile = Task { @MainActor in
            let result = try await sync.reconcile(project: project, library: library, connection: connection, tree: service.tree, textBases: [:], check: {})
            finished = true
            return result
        }
        try await Task.sleep(for: .milliseconds(80))
        check(!finished && service.operations.isEmpty, "A running preview delays actual file mutations without failing Live startup")
        project.compiling = false
        let result = try await pendingReconcile.value
        check(result.reconnect && service.files == plan.result, "Staged upload, replacement and deletion reach the expected remote result")
        check(try OverleafLiveFiles.scan(root) == plan.result && project.treeFiles.contains("server.png"), "Remote additions install into disk and the visible file tree")
        check(service.files.keys.allSatisfy { !$0.hasPrefix("remile-") }, "Confirmed temporary remote files are cleaned up")
        check(FileManager.default.fileExists(atPath: sync.recovery!.appendingPathComponent("after-remote.json").path), "Recovery preserves the exact parked remote bytes before deletion")
        check(!(try await sync.changed(project)), "Installed image hashes do not trigger an upload loop")
        project.compiling = true
        let unchanged = try await sync.reconcile(project: project, library: library, connection: connection, tree: service.tree, textBases: [:], check: {})
        check(!unchanged.reconnect && project.compiling, "An unchanged project can connect while the initial PDF compiles")
        project.compiling = false
        try bytes("Finder replacement").write(to: root.appendingPathComponent("figure.png"), options: .atomic)
        check(try await sync.changed(project), "A binary replacement outside the editor is detected")
        let assetBefore = try OverleafLiveFiles.scan(root)
        let racing = FileRemoteFixture(service.files); racing.racePark = true
        let racingSync = OverleafFileSync(makeRemote: { _ in racing })
        do { _ = try await racingSync.reconcile(project: project, library: library, connection: connection, tree: racing.tree, textBases: [:], check: {}); fatalError("Race ignored") }
        catch { check(racing.files.values.contains(bytes("racing edit")) && racing.operations.allSatisfy { !$0.hasPrefix("delete:") }, "An edit racing replacement is retained remotely and pauses cleanup") }
        check(try OverleafLiveFiles.scan(root) == assetBefore, "A failed remote transaction does not replace local work")
        let intentFile = OverleafFileSync.baseline(connection, library: library.directory).deletingLastPathComponent().appendingPathComponent("pending.json")
        do { _ = try await racingSync.reconcile(project: project, library: library, connection: connection, tree: racing.tree, textBases: [:], check: {}); fatalError("Racing recovery discarded") }
        catch { check(racing.files.values.contains(bytes("racing edit")), "Reconnect preserves a parked concurrent edit and still requires review") }
        try FileManager.default.removeItem(at: intentFile)
        let lost = FileRemoteFixture(service.files); lost.loseUpload = true
        let lostSync = OverleafFileSync(makeRemote: { _ in lost })
        do { _ = try await lostSync.reconcile(project: project, library: library, connection: connection, tree: lost.tree, textBases: [:], check: {}); fatalError("Lost reply ignored") }
        catch { check(lost.operations.count == 1 && lost.files["figure.png"] == service.files["figure.png"], "A lost upload response does not delete or overwrite the remote original") }
        lost.loseUpload = false
        let recovery = try await lostSync.reconcile(project: project, library: library, connection: connection, tree: lost.tree, textBases: [:], check: {})
        check(recovery.reconnect && lost.files == service.files, "Reconnect identifies and removes only the unconfirmed staged upload")
        _ = try await lostSync.reconcile(project: project, library: library, connection: connection, tree: lost.tree, textBases: [:], check: {})
        check(lost.files["figure.png"] == bytes("Finder replacement"), "After recovery the intended image update can complete once")
        let edit = FileRemoteFixture(lost.files)
        edit.onSnapshot = { project.buffers["main.tex"] = String(data: main, encoding: .utf8)! + "% typed while syncing\n" }
        let editSync = OverleafFileSync(makeRemote: { _ in edit })
        do { _ = try await editSync.reconcile(project: project, library: library, connection: connection, tree: edit.tree, textBases: [:], check: {}); fatalError("New typing overwritten") }
        catch { check(project.buffers["main.tex"]!.contains("typed while syncing") && edit.operations.isEmpty, "Typing during file preflight is preserved and prevents stale remote operations") }
        _ = project.save()
        // Premium adds a private Git recovery ref and keeps the current branch and index intact.
        _ = try OverleafGit.run(["init", "-b", "master"], at: root)
        _ = try OverleafGit.run(["add", "--all"], at: root)
        _ = try OverleafGit.run(["commit", "-m", "Fixture base"], at: root)
        let head = try OverleafGit.run(["rev-parse", "HEAD"], at: root).text
        let indexBefore = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        connection.liveOnly = nil; library.setPlan(.premium, premiumProjectAccess: false, for: account.id)
        try bytes("Premium image").write(to: root.appendingPathComponent("figure.png"), options: .atomic)
        let premium = FileRemoteFixture(lost.files), premiumSync = OverleafFileSync(makeRemote: { _ in premium })
        _ = try await premiumSync.reconcile(project: project, library: library, connection: connection, tree: premium.tree, textBases: [:], check: {})
        check(try OverleafGit.run(["rev-parse", "HEAD"], at: root).text == head && Data(contentsOf: root.appendingPathComponent(".git/index")) == indexBefore, "Premium recovery does not move HEAD or alter the user's index")
        check(try !OverleafGit.run(["for-each-ref", "refs/remile/live-recovery"], at: root).text.isEmpty, "Premium file changes create a private Git recovery ref")
        let bare = run.appendingPathComponent("server.git")
        _ = try OverleafGit.run(["init", "--bare", bare.path], at: run)
        _ = try OverleafGit.run(["-c", "protocol.file.allow=always", "push", bare.path, "HEAD:refs/heads/master"], at: root)
        let server = try OverleafLiveFiles.scan(root)
        var desired = server; desired["figure.png"] = bytes("Git image"); desired["official.tex"] = bytes("New document")
        desired["new.tex"] = nil
        let gitRecovery = run.appendingPathComponent("official-publish"); try FileManager.default.createDirectory(at: gitRecovery, withIntermediateDirectories: true)
        // The fixture server starts at HEAD, so its expected image comes from that commit.
        var committed: [String: Data] = [:]
        for path in server.keys { committed[path] = try OverleafGit.run(["show", "HEAD:" + path], at: root, allowFailure: true).data }
        let expectedGitPlan = try OverleafLiveFiles.plan(base: committed, local: desired, remote: committed, joinedText: ["main.tex"])
        try OverleafGitLiveFiles.publish(expectedGitPlan, connection: connection, root: root, recovery: gitRecovery, transport: bare.path)
        check(try OverleafGit.run(["show", "master:figure.png"], at: bare).data == bytes("Git image") && OverleafGit.run(["show", "master:official.tex"], at: bare).data == bytes("New document"), "Premium publishes binary replacements and additions through Git")
        check(try OverleafGit.run(["cat-file", "-e", "master:new.tex"], at: bare, allowFailure: true).status != 0, "Premium Git publishes file deletion")
        check(try OverleafGit.run(["rev-parse", "HEAD"], at: root).text == head && Data(contentsOf: root.appendingPathComponent(".git/index")) == indexBefore, "Premium publishing keeps the open worktree's HEAD and index intact")
        var racedLocal = desired; racedLocal["figure.png"] = bytes("Next Git image")
        let racePlan = try OverleafLiveFiles.plan(base: desired, local: racedLocal, remote: desired, joinedText: ["main.tex"])
        let raceRecovery = run.appendingPathComponent("raced-publish"); try FileManager.default.createDirectory(at: raceRecovery, withIntermediateDirectories: true)
        do {
            try OverleafGitLiveFiles.publish(racePlan, connection: connection, root: root, recovery: raceRecovery, transport: bare.path, beforePush: {
                let commit = try OverleafGit.run(["commit-tree", "master^{tree}", "-p", "master", "-m", "Concurrent browser update"], at: bare).text.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = try OverleafGit.run(["update-ref", "refs/heads/master", commit], at: bare)
            })
            fatalError("Racing push accepted")
        } catch { check(try OverleafGit.run(["show", "master:figure.png"], at: bare).data == bytes("Git image"), "A concurrent server commit rejects the Git push without force or remote overwrite") }
        let integratedConnection = OverleafConnection(id: UUID(), profileID: account.id, projectID: String(repeating: "e", count: 24), name: "Integrated", account: account.name, branch: "master", liveOnly: true)
        let integratedRoot = library.root(integratedConnection)
        try FileManager.default.createDirectory(at: integratedRoot, withIntermediateDirectories: true)
        try main.write(to: integratedRoot.appendingPathComponent("main.tex"))
        let integrated = try TeXProject(integratedRoot, historyEnabled: false)
        try OverleafLiveFiles.save(["main.tex": main], to: OverleafFileSync.baseline(integratedConnection, library: library.directory))
        let integratedRemote = FileRemoteFixture(["main.tex": main])
        let driver = OverleafFileSync(makeRemote: { _ in integratedRemote })
        var channels: [FileLiveFixtureChannel] = []
        let live = OverleafLiveWorkspace(files: driver, authenticate: { _ in }, makeChannel: { _ in
            let channel = FileLiveFixtureChannel(remote: integratedRemote, project: integratedConnection.projectID); channels.append(channel); return channel
        })
        var previousWriter: OverleafLiveWriterLease? = try library.writerLease(integratedConnection)
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(80)); previousWriter = nil }
        await live.start(project: integrated, library: library, connection: integratedConnection)
        check(previousWriter == nil && live.connected, "A short writer handoff during project switching reconnects automatically")
        check(live.connected, "Workspace joins text Live after the file manifest is reconciled")
        let image = run.appendingPathComponent("dropped.png"); try bytes("dropped image").write(to: image)
        integrated.drop([image], into: ""); await live.flush()
        try await eventually { live.connected && integratedRemote.files["dropped.png"] == bytes("dropped image") }
        check(live.issue == nil && channels.count >= 3, "A dropped file automatically uploads and Live reconnects without manual Git review")
        try bytes("replacement").write(to: integratedRoot.appendingPathComponent("dropped.png"), options: .atomic)
        try await eventually { live.connected && integratedRemote.files["dropped.png"] == bytes("replacement") }
        check(live.issue == nil, "External image replacement automatically reaches Overleaf")
        let remoteEntry = integratedRemote.entries["dropped.png"]!
        try integratedRemote.delete(remoteEntry); await channels.last!.changed()
        try await eventually { live.connected && !integrated.treeFiles.contains("dropped.png") }
        check(live.issue == nil && !FileManager.default.fileExists(atPath: integratedRoot.appendingPathComponent("dropped.png").path), "A remote deletion automatically removes the local file and updates the sidebar")
        let externalSource = integratedRoot.appendingPathComponent("external.tex")
        try bytes("External source").write(to: externalSource)
        try await eventually { live.connected && integratedRemote.files["external.tex"] == bytes("External source") && integrated.buffers["external.tex"] == "External source" }
        check(live.issue == nil, "An externally added source uploads and becomes an editable Live document")
        try FileManager.default.removeItem(at: externalSource)
        await live.flush()
        try await eventually { live.connected && integratedRemote.files["external.tex"] == nil && integrated.buffers["external.tex"] == nil }
        check(live.issue == nil, "External source deletion takes the file reconciliation path instead of reading a missing OT file")
        _ = try await integratedRemote.upload(bytes("Remote source"), path: "external.tex", root: integratedRemote.tree.folders[""]!)
        await channels.last!.changed()
        try await eventually { live.connected && integrated.buffers["external.tex"] == "Remote source" }
        check(live.issue == nil, "An Overleaf source addition becomes editable locally without reconnecting manually")
        try integratedRemote.delete(integratedRemote.entries["external.tex"]!); await channels.last!.changed()
        try await eventually { live.connected && integrated.buffers["external.tex"] == nil }
        check(!integrated.treeFiles.contains("external.tex"), "Remote source deletion removes its buffer and sidebar entry")
        await live.stop()
        print("Passed Live file reconciliation checks."); exit(0)
    } catch { print("FAILED:", error); exit(1) }
}
RunLoop.main.run()
