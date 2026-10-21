import Foundation

/// One app-level boundary for explicit network sessions and network child processes.
final class NetworkAccessGate: NSObject, @unchecked Sendable {
    static let preference = "network.workOffline"
    static let changed = Notification.Name("remile.networkAccessChanged")
    struct Offline: LocalizedError { var errorDescription: String? { "Offline mode is on. Turn it off to use online services." } }
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var active: [UUID: () -> Void] = [:]
    init(defaults: UserDefaults) { self.defaults = defaults; super.init() }
    var offline: Bool { defaults.bool(forKey: Self.preference) }
    func requireOnline() throws { if offline { throw Offline() } }
    func setOffline(_ value: Bool) {
        lock.lock(); defaults.set(value, forKey: Self.preference)
        let cancel = value ? Array(active.values) : []; if value { active.removeAll() }; lock.unlock()
        for stop in cancel { stop() }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    func watch(_ cancel: @escaping () -> Void) throws -> UUID {
        lock.lock(); defer { lock.unlock() }; try requireOnline()
        let id = UUID(); active[id] = cancel; return id
    }
    func release(_ id: UUID) { lock.lock(); active.removeValue(forKey: id); lock.unlock() }
    func watch(_ session: URLSession) throws -> UUID { try watch { session.invalidateAndCancel() } }
    func start(_ process: Process) throws -> UUID {
        lock.lock(); defer { lock.unlock() }; try requireOnline()
        try process.run()
        let id = UUID(); active[id] = { if process.isRunning { process.terminate() } }; return id
    }
}
enum NetworkAccess {
    static let gate = NetworkAccessGate(defaults: .standard)
    static var offline: Bool { gate.offline }
    static func requireOnline() throws { try gate.requireOnline() }
}
