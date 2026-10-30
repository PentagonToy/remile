import Foundation

protocol OverleafLiveChannel: Sendable {
    var events: AsyncStream<OverleafLiveSocket.Event> { get }
    func connect() async throws -> OverleafLiveWire.JSON
    func join(_ document: String) async throws -> OverleafLive.Snapshot
    func leave(_ document: String) async throws
    func submit(_ operation: OverleafLive.Submission) async throws
    func stop() async
    func catchUp(_ document: String, version: Int) async throws -> OverleafLiveWire.CatchUp?
    func sourceID() async -> String?
}
extension OverleafLiveChannel {
    func sourceID() async -> String? { nil }
    func catchUp(_ document: String, version: Int) async throws -> OverleafLiveWire.CatchUp? { nil }
}

/// Socket.IO routing is native. WebKit owns the account-origin network context.
actor OverleafLiveSocket: OverleafLiveChannel {
    typealias JSON = OverleafLiveWire.JSON
    struct Event: Sendable { let name: String; let args: [JSON]; var failure: (any Error)? = nil }
    nonisolated let events: AsyncStream<Event>
    private let output: AsyncStream<Event>.Continuation
    private var canSkipLeave = false
    private var publicID: String?
    func sourceID() -> String? { publicID }
    private var browser: OverleafLiveBrowser?
    private var reader: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var joining: CheckedContinuation<JSON, Error>?
    private struct Request { let reply: CheckedContinuation<[JSON], Error>; let timer: Task<Void, Never> }
    private var requests: [Int: Request] = [:]
    private var sequence = 0
    private var epoch = UUID()
    private var lastFrame = Date()
    private let project: String
    private let profile: UUID
    init(project: String, profile: UUID) {
        self.project = project; self.profile = profile
        let stream = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingOldest(1_000))
        events = stream.stream; output = stream.continuation
    }
    func connect() async throws -> JSON {
        try NetworkAccess.requireOnline(); try Task.checkCancellation()
        try OverleafLive.Key(profile: profile, project: project, document: project).validate()
        guard browser == nil else { throw OverleafLiveWire.Failure.protocolMismatch }
        let attempt = epoch
        do {
            let browser = await OverleafLiveBrowser(profile: profile, project: project)
            self.browser = browser
            try await browser.open()
            try NetworkAccess.requireOnline(); try Task.checkCancellation()
            guard epoch == attempt else { throw CancellationError() }
            lastFrame = Date()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    joining = continuation
                    reader = Task { await self.receive(epoch: attempt) }
                    watchdog = Task {
                        do {
                            try await Task.sleep(for: .seconds(20))
                            if self.joining != nil { self.fail(OverleafLiveWire.Failure.timeout, epoch: attempt); return }
                            while !Task.isCancelled {
                                try await Task.sleep(for: .seconds(20))
                                if Date().timeIntervalSince(self.lastFrame) > 90 { self.fail(OverleafLiveWire.Failure.timeout, epoch: attempt); return }
                            }
                        } catch { }
                    }
                }
            } onCancel: { Task { await self.stop() } }
        } catch { fail(error, epoch: attempt); throw error }
    }
    func join(_ document: String) async throws -> OverleafLive.Snapshot {
        let response = try await request("joinDoc", [.string(document), .int(-1), .object(["encodeRanges": .bool(true)])])
        if response.count > 5, case .bool(true) = response[5]["canSkipLeaveDoc"] { canSkipLeave = true }
        return try OverleafLiveWire.snapshot(response)
    }
    func catchUp(_ document: String, version: Int) async throws -> OverleafLiveWire.CatchUp? {
        let response = try await request("joinDoc", [.string(document), .int(version), .object(["encodeRanges": .bool(true)])])
        let snapshot = try OverleafLiveWire.snapshot(response)
        guard response.count > 2, let operations = response[2].array else { throw OverleafLiveWire.Failure.uncertain }
        if response.count > 5, case .bool(true) = response[5]["canSkipLeaveDoc"] { canSkipLeave = true }
        return .init(snapshot: snapshot, operations: operations)
    }
    func submit(_ operation: OverleafLive.Submission) async throws {
        guard operation.key.project == project, operation.key.profile == profile else { throw OverleafLive.Failure.invalidIdentity }
        _ = try await request("applyOtUpdate", [.string(operation.key.document), OverleafLiveWire.update(operation)])
        // RPC confirms queuing. OtUpdateApplied confirms application.
    }
    func leave(_ document: String) async throws {
        if canSkipLeave { return }
        _ = try await request("leaveDoc", [.string(document)])
    }
    func stop() async { fail(CancellationError(), epoch: epoch); await closing?.value }
    private func request(_ name: String, _ args: [JSON]) async throws -> [JSON] {
        try NetworkAccess.requireOnline(); try Task.checkCancellation()
        guard let browser, requests.count < 100, sequence < Int.max else { throw OverleafLiveWire.Failure.disconnected }
        sequence += 1; let id = sequence, attempt = epoch
        let message = try OverleafLiveWire.event(name, args, id: id)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { reply in
                let timer = Task {
                    do { try await Task.sleep(for: .seconds(15)); OverleafLiveDiagnostics.note("rpc-timeout-" + name); self.fail(OverleafLiveWire.Failure.timeout, epoch: attempt) } catch { }
                }
                requests[id] = Request(reply: reply, timer: timer)
                Task {
                    do { try await browser.send(message) }
                    catch { self.fail(error, epoch: attempt) }
                }
            }
        } onCancel: { Task { await self.stop() } }
    }
    private func receive(epoch expected: UUID) async {
        do {
            guard let browser else { throw OverleafLiveWire.Failure.disconnected }
            for try await text in browser.messages {
                guard epoch == expected else { return }; try NetworkAccess.requireOnline(); lastFrame = Date()
                if text.hasPrefix("7:") { OverleafLiveDiagnostics.note("server-error-packet") }
                let packet: OverleafLiveWire.Packet
                do { packet = try OverleafLiveWire.decode(text) }
                catch {
                    OverleafLiveDiagnostics.note("wire-decode-kind", code: Int(text.prefix(1)) ?? -1)
                    OverleafLiveDiagnostics.note("wire-decode-bytes", code: text.utf8.count)
                    throw error
                }
                switch packet {
                case .heartbeat: OverleafLiveDiagnostics.note("heartbeat"); try await browser.send("2::")
                case .closed: OverleafLiveDiagnostics.note("server-disconnect"); throw OverleafLiveWire.Failure.disconnected
                case .acknowledgement(let id, let args):
                    guard let request = requests.removeValue(forKey: id) else { continue }
                    OverleafLiveDiagnostics.note("rpc-ack", code: id)
                    request.timer.cancel()
                    if let error = args.first, error != .null { request.reply.resume(throwing: OverleafLiveWire.Failure.permission) }
                    else { request.reply.resume(returning: Array(args.dropFirst())) }
                case .event(let name, let args):
                    if ["otUpdateApplied", "forceDisconnect", "connectionRejected", "otUpdateError"].contains(name) { OverleafLiveDiagnostics.note(name) }
                    if name == "joinProjectResponse" {
                        OverleafLiveDiagnostics.note("join-project-response")
                        guard let value = args.first, ["readAndWrite", "owner"].contains(value["permissionsLevel"].string ?? ""), value["publicId"].string != nil else { throw OverleafLiveWire.Failure.permission }
                        publicID = value["publicId"].string
                        guard let joining else { throw OverleafLiveWire.Failure.protocolMismatch }
                        self.joining = nil; joining.resume(returning: value["project"])
                    } else if name == "connectionAccepted" {
                        Task {
                            do {
                                let response = try await self.request("joinProject", [.object(["project_id": .string(self.project)])])
                                guard response.count >= 2, ["readAndWrite", "owner"].contains(response[1].string ?? "") else { throw OverleafLiveWire.Failure.permission }
                                if let joining = self.joining { self.joining = nil; joining.resume(returning: response[0]) }
                            } catch { self.fail(error, epoch: expected) }
                        }
                    } else if name == "connectionRejected" || name == "forceDisconnect" { throw OverleafLiveWire.Failure.permission }
                    else if name == "otUpdateError" { throw OverleafLiveWire.Failure.protocolMismatch }
                    else {
                        if case .dropped = output.yield(Event(name: name, args: args)) { OverleafLiveDiagnostics.note("event-buffer-overflow"); throw OverleafLiveWire.Failure.protocolMismatch }
                    }
                case .connected, .ignored: break
                }
            }
        } catch { fail(error, epoch: expected) }
    }
    private func fail(_ error: Error, epoch expected: UUID) {
        guard epoch == expected else { return }; epoch = UUID()
        if let failure = error as? OverleafLiveWire.Failure {
            let stage: String
            switch failure {
            case .protocolMismatch: stage = "protocol-mismatch"
            case .disconnected: stage = "disconnected"
            case .timeout: stage = "timeout"
            case .permission: stage = "permission"
            default: stage = "other"
            }
            OverleafLiveDiagnostics.note("socket-" + stage)
        } else if !(error is CancellationError) { OverleafLiveDiagnostics.note("socket-failure", code: (error as NSError).code) }
        joining?.resume(throwing: error); joining = nil
        for request in requests.values { request.timer.cancel(); request.reply.resume(throwing: error) }; requests.removeAll()
        reader?.cancel(); watchdog?.cancel(); reader = nil; watchdog = nil
        let previous = browser; browser = nil
        closing = Task { await previous?.stop() }
        output.yield(Event(name: "remileDisconnected", args: [], failure: error)); output.finish()
    }
    deinit { let previous = browser; Task { await previous?.stop() }; output.finish() }
}
