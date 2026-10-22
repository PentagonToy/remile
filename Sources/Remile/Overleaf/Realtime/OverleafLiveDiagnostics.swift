import Foundation

/// Development evidence contains stage names and numeric codes, never frames or credentials.
enum OverleafLiveDiagnostics {
    private static let lock = NSLock()
    private static let writer = DispatchQueue(label: "local.remile.live-diagnostics", qos: .utility)
    private static var entries: [[String: String]] = []
    private static var pending = false
    static var snapshot: [[String: String]] { lock.lock(); defer { lock.unlock() }; return entries }
    static func note(_ stage: String, code: Int? = nil) {
        guard Bundle.main.bundleIdentifier == "local.remile.app" else { return }
        lock.lock()
        var row = ["stage": stage, "time": String(Date().timeIntervalSince1970)]
        if let code { row["code"] = String(code) }
        entries.append(row); if entries.count > 100 { entries.removeFirst(entries.count - 100) }
        let schedule = !pending; pending = true; lock.unlock()
        if schedule { writer.asyncAfter(deadline: .now() + .milliseconds(250)) { flush() } }
    }
    private static func flush() {
        lock.lock(); let snapshot = entries; pending = false; lock.unlock()
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("local.remile.app/Overleaf/Live")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent("diagnostics.json")
            try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { }
    }
}
