import Foundation

struct TeXBuild: Sendable {
    let pdf: URL
    let source: URL
    let executable: URL
    let buffers: [String: String]
    let main: String
}

enum TeXSync {
    struct TextHint: Equatable, Sendable { let text: String; let offset: Int }
    struct PDFLocation: Equatable, Sendable { let page: Int; let x: Double; let y: Double; var hint: TextHint? = nil }
    struct SourceLocation: Equatable, Sendable { let file: String; let line: Int; var range: NSRange? = nil }
    struct Failure: LocalizedError { let errorDescription: String? }
    static func hint(in source: String, offset: Int) -> TextHint? {
        let text = source as NSString
        guard offset >= 0, offset < text.length else { return nil }
        let start = max(0, offset - 180), count = min(360, text.length - start)
        let window = text.substring(with: NSRange(location: start, length: count)) as NSString
        let cleaned = NSMutableString(string: window)
        let commands = try! NSRegularExpression(pattern: #"\\[A-Za-z@]+\*?|(?<!\\)%[^\n]*"#)
        for match in commands.matches(in: window as String, range: NSRange(location: 0, length: window.length)).reversed() { cleaned.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length)) }
        return TextHint(text: cleaned as String, offset: offset - start)
    }
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
    /// Preserve precise ranges only for the compiled source. Shift an unchanged
    /// suffix after edits above it, otherwise navigate to a clamped coarse line.
    static func relocate(_ location: SourceLocation, from previous: String, to current: String) -> SourceLocation {
        guard previous != current else { return location }
        let old = previous.components(separatedBy: "\n"), new = current.components(separatedBy: "\n")
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix, old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        let line = location.line >= old.count - suffix ? location.line + new.count - old.count : location.line
        return .init(file: location.file, line: max(0, min(new.count - 1, line)))
    }
    /// Refine only a small SyncTeX neighbourhood. Ambiguous or weak matches keep the line result.
    static func refine(_ location: SourceLocation, source: String, hint: TextHint?) -> SourceLocation {
        guard location.line >= 0, let hint, hint.text.utf16.count <= 500 else { return location }
        let text = source as NSString
        var index = 0
        for _ in 0..<min(location.line, 100_000) {
            guard index < text.length else { return location }
            index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
        }
        let start = max(0, index - 4000), count = min(16000, text.length - start)
        guard count > 0 else { return location }
        let window = text.substring(with: NSRange(location: start, length: count)) as NSString
        let cleaned = NSMutableString(string: window)
        let commands = try! NSRegularExpression(pattern: #"\\[A-Za-z@]+\*?|(?<!\\)%[^\n]*"#)
        for match in commands.matches(in: window as String, range: NSRange(location: 0, length: window.length)).reversed() {
            cleaned.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
        }
        let words = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)
        func tokens(_ string: NSString) -> [(word: String, range: NSRange)] {
            words.matches(in: string as String, range: NSRange(location: 0, length: string.length)).map {
                (string.substring(with: $0.range).decomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")), $0.range)
            }
        }
        let pdf = tokens(hint.text as NSString), code = tokens(cleaned)
        guard let anchor = pdf.firstIndex(where: { NSLocationInRange(hint.offset, $0.range) }), pdf[anchor].word.count >= 2 else { return location }
        var matches: [(index: Int, score: Int)] = []
        for candidate in code.indices where code[candidate].word == pdf[anchor].word {
            var score = 1
            for direction in [-1, 1] {
                for step in 1...8 {
                    let a = anchor + direction * step, b = candidate + direction * step
                    guard pdf.indices.contains(a), code.indices.contains(b), pdf[a].word == code[b].word else { break }
                    score += 1
                }
            }
            if score >= 4 { matches.append((candidate, score)) }
        }
        matches.sort { $0.score > $1.score }
        guard let best = matches.first, matches.count == 1 || best.score >= matches[1].score + 2 else { return location }
        let range = NSRange(location: start + code[best.index].range.location, length: code[best.index].range.length)
        return SourceLocation(file: location.file, line: (text.substring(to: range.location)).filter { $0 == "\n" }.count, range: range)
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
