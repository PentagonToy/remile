import Foundation

struct TeXBuild: Sendable {
    let pdf: URL
    let source: URL
    let executable: URL
    let buffers: [String: String]
    let main: String
}

enum TeXSync {
    struct PDFLocation: Equatable, Sendable { let page: Int; let x: Double; let y: Double }
    struct SourceLocation: Equatable, Sendable { let file: String; let line: Int }
    struct Failure: LocalizedError { let errorDescription: String? }
    static func forward(_ build: TeXBuild, file: String, line: Int) throws -> PDFLocation {
        let output = try run(build, arguments: ["view", "-i", "\(line + 1):0:\(build.source.appendingPathComponent(file).path)", "-o", build.pdf.path])
        let values = fields(output)
        guard let page = values["Page"].flatMap(Int.init), let x = values["x"].flatMap(Double.init), let y = values["y"].flatMap(Double.init), page > 0, x.isFinite, y.isFinite else { throw Failure(errorDescription: "No PDF location for this line.") }
        return PDFLocation(page: page, x: x, y: y)
    }
    static func reverse(_ build: TeXBuild, location: PDFLocation) throws -> SourceLocation {
        let output = try run(build, arguments: ["edit", "-o", "\(location.page):\(location.x):\(location.y):\(build.pdf.path)"])
        let values = fields(output)
        guard let input = values["Input"], let line = values["Line"].flatMap(Int.init), line > 0 else { throw Failure(errorDescription: "No source location at this point.") }
        let url = URL(fileURLWithPath: input, relativeTo: build.source).standardizedFileURL
        let prefix = build.source.standardizedFileURL.path + "/"
        guard url.path.hasPrefix(prefix) else { throw Failure(errorDescription: "This location belongs to an external TeX package.") }
        let file = String(url.path.dropFirst(prefix.count))
        guard build.buffers[file] != nil else { throw Failure(errorDescription: "This file is not editable in the project.") }
        return SourceLocation(file: file, line: line - 1)
    }
    /// The first result block is the closest candidate. No editor commands are executed.
    static func fields(_ output: String) -> [String: String] {
        var result: [String: String] = [:], active = false
        for line in output.components(separatedBy: .newlines) {
            if line == "SyncTeX result begin" { active = true; continue }
            guard active else { continue }
            if line == "SyncTeX result end" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            if key == "Output", result["Output"] != nil { break }
            if result[key] == nil { result[key] = String(line[line.index(after: colon)...]) }
        }
        return result
    }
    private static func run(_ build: TeXBuild, arguments: [String]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: build.executable.path) else { throw Failure(errorDescription: "SyncTeX not found in the configured TeX directory.") }
        let log = build.pdf.deletingLastPathComponent().appendingPathComponent("sync-" + UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: log) }
        let process = Process(); process.executableURL = build.executable; process.arguments = arguments; process.currentDirectoryURL = build.source
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SYNCTEX_EDITOR"); environment.removeValue(forKey: "SYNCTEX_VIEWER")
        process.environment = environment; process.standardOutput = handle; process.standardError = handle
        try process.run(); let deadline = Date().addingTimeInterval(5)
        while process.isRunning {
            if Date() > deadline { process.terminate(); throw Failure(errorDescription: "SyncTeX timed out.") }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(errorDescription: "SyncTeX could not resolve this location.") }
        return String(decoding: try Data(contentsOf: log), as: UTF8.self)
    }
}
