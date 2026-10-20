import Foundation
import Network

/// OAuth listener is bound to loopback only and exists only during sign-in.
@MainActor final class ChatGPTCallback {
    let listener: NWListener
    let state: String
    let values: AsyncThrowingStream<[String: String], Error>
    private let continuation: AsyncThrowingStream<[String: String], Error>.Continuation
    private var timer: Task<Void, Never>?
    private var complete = false
    private var ready: CheckedContinuation<Void, Error>?
    init(state: String) throws {
        self.state = state
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        var continuation: AsyncThrowingStream<[String: String], Error>.Continuation!
        values = AsyncThrowingStream { continuation = $0 }; self.continuation = continuation
    }
    func start() async throws -> String {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            self.ready = ready
            listener.stateUpdateHandler = { [weak self] status in Task { @MainActor in
                guard let self else { return }
                switch status {
                case .ready: self.ready?.resume(); self.ready = nil
                case .failed(let error): self.ready?.resume(throwing: error); self.ready = nil
                case .cancelled: self.ready?.resume(throwing: CancellationError()); self.ready = nil
                default: break
                }
            }
            }
            listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.receive(connection) } }
            listener.start(queue: .main)
        }
        guard let port = listener.port else { throw ChatGPTIdentity.Failure("Could not open the sign-in callback.") }
        timer = Task { [weak self] in do { try await Task.sleep(for: .seconds(180)); self?.cancel() } catch { } }
        return "http://127.0.0.1:\(port.rawValue)/auth/callback"
    }
    func cancel() { guard !complete else { return }; complete = true; timer?.cancel(); listener.cancel(); continuation.finish(throwing: CancellationError()) }
    private func receive(_ connection: NWConnection, buffer: Data = Data()) {
        if buffer.isEmpty { connection.start(queue: .main) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, ended, error in
            Task { @MainActor in
                guard let self, !self.complete else { connection.cancel(); return }
                let bytes = buffer + (data ?? Data())
                guard bytes.count <= 16_384, error == nil else { connection.cancel(); return }
                guard let raw = String(data: bytes, encoding: .utf8), raw.contains("\r\n\r\n") else { if !ended { self.receive(connection, buffer: bytes) } else { connection.cancel() }; return }
                let target = raw.components(separatedBy: "\r\n").first?.split(separator: " ")
                guard target?.first == "GET", let path = target?.dropFirst().first, let result = Self.parse(String(path), state: self.state) else {
                    connection.send(content: Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() }); return
                }
                let body = "Sign-in received. You can return to remile."
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)".utf8), completion: .contentProcessed { _ in connection.cancel() })
                self.complete = true; self.timer?.cancel(); self.listener.cancel(); self.continuation.yield(result); self.continuation.finish()
            }
        }
    }
    nonisolated static func parse(_ path: String, state: String) -> [String: String]? {
        guard path.hasPrefix("/auth/callback?"), let components = URLComponents(string: "http://127.0.0.1" + path), components.path == "/auth/callback", components.fragment == nil else { return nil }
        var result = [String: String]()
        for item in components.queryItems ?? [] { guard result[item.name] == nil, let value = item.value else { return nil }; result[item.name] = value }
        guard result["state"] == state, result["code"] != nil || result["error"] != nil else { return nil }
        return result
    }
}
