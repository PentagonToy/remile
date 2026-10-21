import Foundation

struct TeXPackageResolution: Sendable {
    var owners: [String: [String]] = [:]
    var notice: String? = nil
    var managerNeedsUpdate = false
}

/// Queries repository metadata only. Package installation always remains a separate user action.
actor TeXPackageResolver {
    static let shared = TeXPackageResolver()
    private var cache: [String: (Date, TeXPackageResolution)] = [:]
    func resolve(files: [String], directory: String) async -> TeXPackageResolution {
        let key = directory + "|" + files.sorted().joined(separator: "|")
        if let saved = cache[key], Date().timeIntervalSince(saved.0) < 300 { return saved.1 }
        let task = Task.detached(priority: .utility) { Self.lookup(files: files, directory: directory) }
        let result = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        if !Task.isCancelled && result.notice == nil {
            if cache.count >= 64 { cache.removeAll() }
            cache[key] = (Date(), result)
        }
        return result
    }
    static func parse(_ output: String, files: [String]) -> TeXPackageResolution {
        var owners: [String: Set<String>] = [:], package: String?
        let requested = Set(files)
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if raw.first?.isWhitespace == false, line.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.+-]*:$"#, options: .regularExpression) != nil {
                package = String(line.dropLast()); continue
            }
            guard let package, line.hasPrefix("texmf-dist/"), !line.contains("/doc/"), !line.contains("/source/") else { continue }
            let file = (line as NSString).lastPathComponent
            if requested.contains(file) { owners[file, default: []].insert(package) }
        }
        return TeXPackageResolution(owners: owners.mapValues { $0.sorted() }, managerNeedsUpdate: output.contains("tlmgr itself needs to be updated"))
    }
    static func lookup(files: [String], directory: String) -> TeXPackageResolution {
        guard !NetworkAccess.offline else { return TeXPackageResolution(notice: "Offline mode is on. Package lookup will be available when online.") }
        guard !files.isEmpty else { return TeXPackageResolution() }
        guard files.count <= 100, files.allSatisfy({ $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil }) else { return TeXPackageResolution(notice: "Check missing project files in diagnostics.") }
        let tool = URL(fileURLWithPath: directory).appendingPathComponent("tlmgr")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { return TeXPackageResolution(notice: "TeX Live Manager is unavailable.") }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("remile-tex-lookup-" + UUID().uuidString)
        FileManager.default.createFile(atPath: path.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: path) }
        do {
            let handle = try FileHandle(forWritingTo: path); defer { try? handle.close() }
            let child = Process(); child.executableURL = tool
            child.arguments = ["search", "--global", "--file", "/(?:" + files.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")$"]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = directory + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            child.environment = environment; child.standardOutput = handle; child.standardError = handle
            let lease = try NetworkAccess.gate.start(child); defer { NetworkAccess.gate.release(lease) }
            let deadline = Date().addingTimeInterval(20)
            while child.isRunning && Date() < deadline && !Task.isCancelled {
                if ((try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 2_000_000 { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if child.isRunning { child.terminate(); return TeXPackageResolution(notice: Task.isCancelled ? "Package lookup cancelled." : "Package lookup timed out. Try again when connected.") }
            child.waitUntilExit()
            let output = String(decoding: try Data(contentsOf: path), as: UTF8.self)
            var result = parse(output, files: files)
            if child.terminationStatus != 0 { result.notice = result.managerNeedsUpdate ? "Update TeX Live Manager, then check again." : "Package lookup failed. Check your connection or TeX repository." }
            return result
        } catch { return TeXPackageResolution(notice: "Package lookup could not start.") }
    }
}
