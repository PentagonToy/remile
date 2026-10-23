import Foundation

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}
func require(_ value: Bool, _ message: String) { precondition(value, message); print("PASS: " + message) }
@MainActor func until(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() { guard ContinuousClock.now < deadline else { throw OverleafLiveWire.Failure.timeout }; try await Task.sleep(for: .milliseconds(20)) }
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
Task { @MainActor in
    do {
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var online = original; online[NetworkAccessGate.preference] = false
        UserDefaults.standard.setVolatileDomain(online, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        let directory = output.appendingPathComponent("library-" + UUID().uuidString)
        let library = OverleafLibrary(directory: directory)
        let account = library.saveAccount(name: "Free fixture", token: "", plan: .free)!
        require(OverleafWebIdentity.dataStore(account.id) === OverleafWebIdentity.dataStore(account.id), "Login, downloads and Live reuse the same account cookie store")
        require(OverleafWebIdentity.dataStore(account.id) !== OverleafWebIdentity.dataStore(UUID()), "Different accounts never share a cookie store")
        let projectID = "6ad72e207e5cd74f01fe6b18", docID = "6ad72e207e5cd74f01fe6b19"
        let zip = try Data(contentsOf: output.deletingLastPathComponent().appendingPathComponent("fixtures/source.zip"))
        var downloads = 0
        await library.connectLive(projectID: projectID, name: "Free project", account: account, download: { id, profile in
            require(id == projectID && profile == account.id, "Import uses the chosen account and project")
            downloads += 1; return zip
        })
        require(library.error == nil && library.projects.count == 1, "A Free account imports without a Git token")
        let connection = library.projects[0], root = library.root(connection)
        require(connection.liveOnly == true && !FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path), "Free imports do not create or depend on a Git repository")
        let assets = try Data(contentsOf: root.appendingPathComponent("images/marker.bin"))
        require(assets == Data([0,1,2,255]) && FileManager.default.fileExists(atPath: root.appendingPathComponent("contents/part.tex").path), "Source imports preserve binary assets and nested folders")
        let project = try TeXProject(root, historyEnabled: false)
        require(project.main == "main.tex" && project.buffers["refs.bib"] != nil, "Imported sources open in the local LaTeX editor")
        let compileRoot = project.root, compileMain = project.main, compileBuffers = project.buffers
        let compilation = try await Task.detached {
            try TeXCompileJob().run(root: compileRoot, main: compileMain, buffers: compileBuffers, configuration: TeXConfiguration(directory: TeXConfiguration.current.directory, engine: .pdf, bibliography: false, timeLimit: 90), output: output.appendingPathComponent("compile-" + UUID().uuidString))
        }.value
        require(compilation.success && PDFDocument(data: compilation.pdf ?? Data())?.pageCount == 1, "A Git-free imported project compiles locally to a one-page PDF")
        let baseline = project.buffers["main.tex"]!
        await library.connectLive(projectID: projectID, name: "Duplicate", account: account, download: { _, _ in downloads += 1; return zip })
        require(downloads == 1 && library.projects.count == 1, "Duplicate imports do not download or replace local work")
        library.error = nil
        let channel = LiveFixtureChannel(project: projectID, document: docID, text: baseline)
        let live = OverleafLiveWorkspace(syncFiles: false, authenticate: { _ in }, makeChannel: { _ in channel })
        await live.start(project: project, library: library, connection: connection)
        require(live.connected && live.issue == nil, "Imported sources join Live using the private baseline rather than Git HEAD")
        let localEdit = baseline.replacingOccurrences(of: "Free project", with: "Edited free project")
        project.buffers["main.tex"] = localEdit
        await live.flush()
        try await until { live.pendingDocumentCount == 0 && live.issue == nil }
        let uploaded = try await channel.join(docID)
        require(uploaded.text == localEdit, "Local text edits reach the Live server and receive confirmation")
        let remoteEdit = localEdit.replacingOccurrences(of: "baseline.", with: "remote change.")
        try await channel.remoteEdit(remoteEdit)
        try await until { project.buffers["main.tex"] == remoteEdit }
        require(try String(contentsOf: root.appendingPathComponent("main.tex"), encoding: .utf8) == remoteEdit, "Remote text edits reach the editor and local source file")
        await live.stop()
        let offlineEdit = remoteEdit + "% Local offline edit\n"
        project.buffers["main.tex"] = offlineEdit
        let rejoin = LiveFixtureChannel(project: projectID, document: docID, text: remoteEdit)
        let reopened = OverleafLiveWorkspace(syncFiles: false, authenticate: { _ in }, makeChannel: { _ in rejoin })
        await reopened.start(project: project, library: library, connection: connection)
        require(reopened.connected && project.buffers["main.tex"] == offlineEdit, "Reopening preserves local edits using the persisted Live checkpoint")
        await reopened.flush(); try await until { reopened.pendingDocumentCount == 0 }
        require(try await rejoin.join(docID).text == offlineEdit, "Offline edits sync after reconnecting")
        try await rejoin.treeChanged(); try await until { reopened.requiresGitReview }
        require(reopened.issue?.contains("Git") == false && reopened.enabled, "Structure changes pause safely with a recovery hint that does not require Premium Git")
        await reopened.stop()
        library.setPlan(.premium, premiumProjectAccess: false, for: account.id)
        require(!library.allowsGit(connection), "Changing the account plan cannot accidentally publish a source-only import through Git")
        let loaded = OverleafLibrary(directory: directory)
        require(loaded.projects.first?.liveOnly == true, "The source-only connection mode survives app restart")
        for name in ["traversal", "git", "backslash", "absolute"] {
            let bad = try Data(contentsOf: output.deletingLastPathComponent().appendingPathComponent("fixtures/" + name + ".zip"))
            let target = output.appendingPathComponent("bad-" + name)
            do { try OverleafSourceArchive.install(bad, at: target, baseline: output.appendingPathComponent(name + ".json")); fatalError("Unsafe archive accepted") }
            catch { require(!FileManager.default.fileExists(atPath: target.path), "Unsafe archive is rejected before writing files: " + name) }
        }
        try await checkLiveWorkspace(output: output.appendingPathComponent("legacy-" + UUID().uuidString), check: require)
        print("Passed Free import, asset preservation, Live editing and reconnect checks without credentials or a remote Git service.")
        exit(0)
    } catch { print("FAILED:", error); exit(1) }
}
RunLoop.main.run()
