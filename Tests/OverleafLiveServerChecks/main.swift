import AppKit

actor InterruptedServerChannel: OverleafLiveChannel {
    nonisolated let events: AsyncStream<OverleafLiveSocket.Event>
    private let output: AsyncStream<OverleafLiveSocket.Event>.Continuation
    private let channel: OverleafLiveSocket
    private var forwarding: Task<Void, Never>?
    private var armed = false
    private(set) var submissions = 0
    init(connection: OverleafConnection) {
        channel = OverleafLiveSocket(project: connection.projectID, profile: connection.profileID)
        let stream = AsyncStream<OverleafLiveSocket.Event>.makeStream(); events = stream.stream; output = stream.continuation
    }
    func connect() async throws -> OverleafLiveWire.JSON {
        let tree = try await channel.connect()
        forwarding = Task { [weak self, channel] in
            for await event in channel.events { guard let self else { return }; await self.forward(event) }
            await self?.finished()
        }
        return tree
    }
    private func forward(_ event: OverleafLiveSocket.Event) {
        if armed && event.name == "otUpdateApplied" { return }
        output.yield(event)
    }
    private func finished() { output.finish() }
    func join(_ document: String) async throws -> OverleafLive.Snapshot { try await channel.join(document) }
    func leave(_ document: String) async throws { try await channel.leave(document) }
    func arm() { armed = true }
    func submit(_ op: OverleafLive.Submission) async throws {
        submissions += 1
        try await channel.submit(op)
        if armed {
            await channel.stop()
            output.yield(.init(name: "remileDisconnected", args: [])); output.finish()
        }
    }
    func stop() async { forwarding?.cancel(); await channel.stop(); output.finish() }
}
// Explicit opt-in: this check writes and removes its own comments in the named real project.
precondition(ProcessInfo.processInfo.environment["REMILE_LIVE_SERVER_CHECK_PROJECT"] == "remile_sample", "Explicit real-project opt-in required")
precondition(CommandLine.arguments.count == 2, "Provide a private external evidence directory")
let serverApp = NSApplication.shared
serverApp.setActivationPolicy(.accessory)
let serverOut = URL(fileURLWithPath: CommandLine.arguments[1])
@MainActor func serverUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(35))
    while !condition() { if ContinuousClock.now >= deadline { throw URLError(.timedOut) }; try await Task.sleep(for: .milliseconds(30)) }
}
Task { @MainActor in
    let library = OverleafLibrary()
    var workspace: OverleafLiveWorkspace?
    var result: [String: Any] = ["method": "real Overleaf transport with applied-update delivery suppressed before controlled disconnect", "project": "remile_sample"]
    do {
        guard let connection = library.projects.first(where: { $0.name == "remile_sample" }) else { throw CocoaError(.fileNoSuchFile) }
        let project = try TeXProject(library.root(connection), historyEnabled: false)
        var channels: [InterruptedServerChannel] = []
        let live = OverleafLiveWorkspace(makeChannel: { c in let channel = InterruptedServerChannel(connection: c); channels.append(channel); return channel })
        workspace = live
        await live.start(project: project, library: library, connection: connection)
        guard live.connected, let first = channels.first else { throw NSError(domain: "LiveServerCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: live.issue ?? "Connection was not established"]) }
        let main = project.main, before = project.buffers[main]!
        let marker = "% remile-live-quality-server-cut-" + UUID().uuidString + "\n"
        try before.write(to: serverOut.appendingPathComponent("server-before.tex"), atomically: true, encoding: .utf8)
        try marker.write(to: serverOut.appendingPathComponent("server-probe.txt"), atomically: true, encoding: .utf8)
        await first.arm()
        project.buffers[main] = marker + before
        await live.flush()
        try await serverUntil { !live.connected && live.issue != nil }
        let reviews = library.directory.appendingPathComponent("Live")
        let journals = try FileManager.default.enumerator(at: reviews, includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" && $0.path.contains(connection.projectID) }
        let retained = journals.contains { url in
            guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let pending = object["inFlight"] as? [String: Any] else { return false }
            return (pending["after"] as? String)?.contains(marker.trimmingCharacters(in: .newlines)) == true
        }
        guard retained, project.buffers[main] == marker + before else { throw NSError(domain: "LiveServerCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unconfirmed intent was not retained"]) }
        result["unconfirmedIntentRetained"] = true
        await live.retry()
        if live.conflict != nil {
            result["recovery"] = "explicit review of uncertain upload"
            await live.choose(false)
        } else { result["recovery"] = "fresh server snapshot recognised applied upload" }
        guard live.connected else { throw NSError(domain: "LiveServerCheck", code: 3, userInfo: [NSLocalizedDescriptionKey: live.issue ?? "Reconnect failed"]) }
        var replayed = 0
        for channel in channels.dropFirst() { replayed += await channel.submissions }
        guard replayed == 0 else { throw NSError(domain: "LiveServerCheck", code: 4, userInfo: [NSLocalizedDescriptionKey: "Uncertain intent was replayed"]) }
        result["replayedSubmissions"] = replayed
        if let current = project.buffers[main], current.hasPrefix(marker) { project.buffers[main] = String(current.dropFirst(marker.count)) }
        await live.flush()
        try await serverUntil { live.pendingDocumentCount == 0 || live.issue != nil }
        guard live.issue == nil, project.buffers[main] == before else { throw NSError(domain: "LiveServerCheck", code: 5, userInfo: [NSLocalizedDescriptionKey: "Probe cleanup needs review"]) }
        result["probeRemoved"] = true; result["status"] = "passed"
        await live.stop()
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: serverOut.appendingPathComponent("server-result.json"))
        print("Real-server controlled disconnect recovery passed; probe removed"); exit(0)
    } catch {
        await workspace?.stop(); result["status"] = "needs attention"; result["reason"] = error.localizedDescription
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: serverOut.appendingPathComponent("server-result.json"))
        print("Real-server check stopped:", error.localizedDescription); exit(1)
    }
}
serverApp.run()
