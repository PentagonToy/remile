import Foundation
final class HeldRequest: URLProtocol {
    static let lock = NSLock()
    private static var received = false
    static var started: Bool { lock.lock(); defer { lock.unlock() }; return received }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.lock(); Self.received = true; Self.lock.unlock() }
    override func stopLoading() { }
}
let isolated = UserDefaults(suiteName: "remile.network-checks." + UUID().uuidString)!
let gate = NetworkAccessGate(defaults: isolated)
let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [HeldRequest.self]
let session = URLSession(configuration: configuration)
Task {
    do {
        let lease = try gate.watch(session)
        let response = Task { try await session.data(from: URL(string: "https://fixture.invalid/held")!) }
        for _ in 0..<100 where !HeldRequest.started { try await Task.sleep(for: .milliseconds(10)) }
        precondition(HeldRequest.started)
        gate.setOffline(true)
        do { _ = try await response.value; fatalError("Active request completed after cancellation") }
        catch let error as URLError { precondition(error.code == .cancelled) }
        gate.release(lease)
        do { try gate.requireOnline(); fatalError("Offline allowed next request") } catch is NetworkAccessGate.Offline { }
        gate.setOffline(false); try gate.requireOnline()
        print("Passed actual URLSession cancellation, offline rejection and resume using an in-process URLProtocol; no network traffic.")
        exit(0)
    } catch { print("FAIL: \(error)"); exit(1) }
}
dispatchMain()
