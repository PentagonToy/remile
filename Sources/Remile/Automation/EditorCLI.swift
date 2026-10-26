import Foundation
import AppKit
import PDFKit

@MainActor enum EditorCLI {
    static func run(_ arguments: [String]) -> Int32 {
        do {
            let command = arguments.first ?? "help", options = Array(arguments.dropFirst())
            try EditorCLIArguments.validate(command: command, options: options)
            func option(_ key: String) -> String? { options.firstIndex(of: key).flatMap { options.indices.contains($0 + 1) ? options[$0 + 1] : nil } }
            switch command {
            case "version", "--version": return emit(["ok": true, "version": RemileRelease.current])
            case "help", "--help":
                return emit(["ok": true, "usage": "remile --cli COMMAND. Live document commands accept --target UUID from documents or status.", "commands": ["overleaf list [--query TEXT] | show|open|read|review --id overleaf:PROJECT_ID [--connection UUID] [--target UUID] [--file relative.tex] [--format json|markdown|bundle] [--output /absolute/new-file]", "review [/absolute/project] [--run|--stop|--clear|--criteria] [--file relative.tex] [--format markdown|json] [--output /absolute/new-file] (run/clear/stop use the running app)", "version", "documents", "diagnostics", "reference recognise --id UUID --expected-revision UUID | storage | passages --id UUID | save-passage --id UUID --attachment UUID --expected-sha256 HASH --page N --start UTF16 --length UTF16 | evidence --id UUID --attachment UUID [--page N] | suggest (--library UUID | --libraries UUID,UUID) [--query text] [--context sentence] [--limit 1..50] | citation --id UUID [--kind latex|markdown] | libraries | list [--library UUID] [--query text] [--sort title|author|publication|year|publisher|key|type|added] [--order asc|desc] [--limit 1..200] [--offset N] [--trash] | show --id UUID | export [--library UUID] [--id UUID] [--output /absolute/new.bib] | import --library UUID --source-file /absolute/file.pdf|file.bib | collect --library UUID --source-file /absolute/file.pdf | update|attach --id UUID --expected-revision UUID --source-file /absolute/file | detach --id UUID --expected-revision UUID --attachment UUID | trash|restore|regenerate-key --id UUID --expected-revision UUID", "library-search \"question or keywords\" [--no-boost] [--offset N]", "pdf-regions /absolute/document.pdf [--page N] [--tables] [--region ID --output /absolute/new.png|new.tsv|new.md --expected-sha256 HASH]", "pdf-read [/absolute/document.pdf] [--page N] [--find text] [--render /absolute/new.png]", "comments [/absolute/document.pdf] [--format markdown|json] [--output /absolute/new.md|new.json]","combine /absolute/one /absolute/two --output /absolute/new.pdf|new.md", "compress /absolute/input.pdf --output /absolute/new.pdf [--quality small|balanced|high] [--grayscale]", "status", "writer-page [--columns 1|2] [--header text|--clear-header] [--footer text|--clear-footer] [--top-line on|off] [--bottom-line on|off] [--page-numbers on|off] [--expected-sha256 HASH] [--target UUID]", "writer-object --id UUID [--wrap on|off] [--lock on|off] [--expected-sha256 HASH] [--target UUID]", "writer-view [--zoom 0.25..2|--fit] [--rulers on|off] [--target UUID]", "logs [--tail characters]", "read [--file relative.tex]", "select --file relative.tex", "replace --file relative.tex --source-file /absolute/file --expected-sha256 HASH", "save [--output /absolute/new-project-directory]", "compile [--scratch] [--submission-check]", "submission-compare [--status]", "history", "doctor", "transform --action strip-notes|embed-bibliography|toggle-comment|indent|outdent [--file relative.tex] [--start UTF16 --length UTF16] [--apply --expected-sha256 HASH]", "rename --file relative.tex --name NEW [--kind project]", "export --kind pdf|source --output /absolute/new-file", "open /absolute/path", "inspect /absolute/project", "build /absolute/project --output /absolute/new-directory [--main main.tex]"]])
            case "review":
                let actions = ["--run", "--stop", "--clear", "--criteria"].filter { options.contains($0) }
                guard actions.count <= 1 else { throw Failure("Choose one review action at a time.") }
                let path = options.first.flatMap { $0.hasPrefix("/") ? $0 : nil }
                var index = path == nil ? 0 : 1
                while index < options.count {
                    let value = options[index]
                    if ["--run", "--stop", "--clear", "--criteria"].contains(value) { index += 1 }
                    else if ["--file", "--format", "--output", "--target"].contains(value), index + 1 < options.count { index += 2 }
                    else { throw Failure("Unknown or incomplete review option.") }
                }
                if options.contains("--criteria") { return emit(try ManuscriptReviewCommands.criteria()) }
                let format = try PDFCommentExport.format(named: option("--format"), output: option("--output"))
                if let path, actions.isEmpty {
                    return emit(try ManuscriptReviewStore.read(root: URL(fileURLWithPath: path)).response(format: format, output: option("--output")))
                }
                guard actions.isEmpty || option("--output") == nil else { throw Failure("Read or export the results after completing the review action.") }
                var request = EditorBridge.Request(operation: "review", file: option("--file"))
                request.source = path; request.action = actions.first.map { String($0.dropFirst(2)) } ?? "read"; request.kind = format.rawValue; request.output = option("--output")
                request.target = option("--target").flatMap(UUID.init(uuidString:))
                return try send(request)
            case "overleaf":
                var request = EditorBridge.Request(operation: "overleaf", file: option("--file"))
                request.action = options.first; request.source = option("--id"); request.name = option("--connection"); request.kind = options.first == "review" ? option("--format") : option("--query"); request.output = option("--output")
                request.target = option("--target").flatMap(UUID.init(uuidString:))
                return try send(request)
            case "reference":
                if options.first == "recognise" {
                    var request = EditorBridge.Request(operation: "reference-recognise", file: option("--id"))
                    request.expectedSHA256 = option("--expected-revision")
                    return try send(request)
                }
                return emit(try ReferenceCLI.response(options))
            case "library-search":
                var words: [String] = [], i = 0
                while i < options.count {
                    if options[i] == "--offset" { i += 2; continue }
                    if options[i] != "--no-boost" { words.append(options[i]) }
                    i += 1
                }
                let query = words.joined(separator: " ")
                _ = try LibraryIndex.queryTerms(query)
                var request = EditorBridge.Request(operation: "library-search")
                request.source = query; request.apply = !options.contains("--no-boost"); request.offset = option("--offset").flatMap(Int.init)
                return try send(request)
            case "pdf-regions":
                NSApplication.shared.setActivationPolicy(.prohibited)
                guard let path = options.first, path.hasPrefix("/"), let page = Int(option("--page") ?? "1"), page > 0 else { throw Failure("Provide a PDF path and a positive page number.") }
                return emit(try PDFRegionCommands.response(path: path, page: page, tables: options.contains("--tables"), region: option("--region"), output: option("--output"), expectedHash: option("--expected-sha256")))
            case "pdf-read":
                let page: Int?
                if let value = option("--page") { guard let number = Int(value), number > 0 else { throw Failure("Use a positive page number.") }; page = number } else { page = nil }
                if let path = options.first, path.hasPrefix("/") {
                    NSApplication.shared.setActivationPolicy(.prohibited)
                    guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { throw Failure("Choose a readable PDF.") }
                    var result = try PDFInspection.read(document, page: page ?? 1, find: option("--find"), render: option("--render")); result["path"] = path
                    return emit(result)
                }
                var request = EditorBridge.Request(operation: "pdf-read"); request.start = page; request.source = option("--find"); request.output = option("--render")
                request.target = option("--target").flatMap(UUID.init(uuidString:))
                return try send(request)
            case "comments":
                let output = option("--output"), format = try PDFCommentExport.format(named: option("--format"), output: output)
                if let path = options.first, path.hasPrefix("/") {
                    NSApplication.shared.setActivationPolicy(.prohibited)
                    guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { throw Failure("Choose a readable PDF.") }
                    let archive = try PDFCommentExport.capture(document, name: URL(fileURLWithPath: path).lastPathComponent)
                    return emit(try PDFCommentExport.response(archive, format: format, output: output))
                }
                var request = EditorBridge.Request(operation: "comments"); request.kind = format.rawValue; request.output = output
                request.target = option("--target").flatMap(UUID.init(uuidString:))
                return try send(request)
            case "combine", "compress":
                guard let output = option("--output"), output.hasPrefix("/"), !FileManager.default.fileExists(atPath: output) else { throw Failure("Choose a new absolute output file.") }
                NSApplication.shared.setActivationPolicy(.prohibited)
                let target = URL(fileURLWithPath: output)
                if command == "combine" {
                    var paths: [String] = [], index = 0
                    while index < options.count {
                        if options[index] == "--output" { index += 2; continue }
                        guard options[index].hasPrefix("/"), FileManager.default.fileExists(atPath: options[index]) else { throw Failure("Provide existing absolute input files.") }
                        paths.append(options[index]); index += 1
                    }
                    guard paths.count >= 2 else { throw Failure("Choose at least two files to combine.") }
                    let inputs = paths.map { URL(fileURLWithPath: $0) }, kind = try DocumentTools.kind(inputs)
                    guard kind == .pdf ? target.pathExtension.lowercased() == "pdf" : target.pathExtension.lowercased() == "md" else { throw Failure("Use .pdf for PDFs or .md for Markdown.") }
                    try DocumentTools.create(.combine, inputs: inputs, destination: target)
                    return emit(["ok": true, "output": output, "inputs": paths.count, "kind": kind.rawValue])
                }
                guard let path = options.first, path.hasPrefix("/"), URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf", target.pathExtension.lowercased() == "pdf" else { throw Failure("Choose PDF input and output files.") }
                let quality: CompressionSettings.Quality
                switch option("--quality") ?? "balanced" { case "small": quality = .small; case "balanced": quality = .balanced; case "high": quality = .high; default: throw Failure("Choose small, balanced or high quality.") }
                let reply = CompressionReply(), input = URL(fileURLWithPath: path), settings = CompressionSettings(grayscale: options.contains("--grayscale"), quality: quality)
                Task.detached {
                    do { reply.set(.success(try await PDFCompressor().prepare(input, settings: settings) { _, _ in })) }
                    catch { reply.set(.failure(error)) }
                }
                while reply.value == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
                let result = try reply.value!.get(); defer { DocumentConverter.discard(result.batch) }
                guard let file = result.batch.outputs.first else { throw Failure("Compression did not produce a PDF.") }
                try Data(contentsOf: file).write(to: target, options: .atomic)
                return emit(["ok": true, "output": output, "originalBytes": result.originalBytes, "outputBytes": result.outputBytes, "reduced": result.reduced])
            case "doctor": return emit(["ok": true, "binaryDirectory": TeXConfiguration.current.directory, "missingTools": TeXConfiguration.current.missingTools(buffers: [:]), "historyMinutes": TeXHistory.intervalMinutes, "installCommand": "brew install --cask mactex-no-gui"])
            case "inspect", "build":
                guard let path = options.first, path.hasPrefix("/") else { throw Failure("Provide an absolute project directory.") }
                let root = URL(fileURLWithPath: path), paths = try TeXFileSystem.paths(root)
                var buffers: [String: String] = [:]
                for file in paths where ["tex", "bib", "sty", "cls"].contains((file as NSString).pathExtension.lowercased()) {
                    let bytes = try Data(contentsOf: root.appendingPathComponent(file)); guard bytes.count <= 4_000_000, let source = String(data: bytes, encoding: .utf8) else { throw Failure("Source is too large or is not UTF-8.") }; buffers[file] = source
                }
                let mains = buffers.keys.filter { buffers[$0]!.contains("\\documentclass") }.sorted()
                if command == "inspect" { return emit(["ok": true, "root": root.path, "files": paths, "mainCandidates": mains, "latexmk": TeXConfiguration.current.available]) }
                guard let output = option("--output"), output.hasPrefix("/"), !FileManager.default.fileExists(atPath: output), !URL(fileURLWithPath: output).standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw Failure("Use a new absolute output directory outside the project.") }
                let main = option("--main") ?? (mains.contains("main.tex") ? "main.tex" : mains.first ?? "")
                guard buffers[main] != nil else { throw Failure("Select a valid main document.") }
                let result = try TeXCompileJob().run(root: root, main: main, buffers: buffers, configuration: .current, output: URL(fileURLWithPath: output), scratch: options.contains("--scratch"), submissionCheck: options.contains("--submission-check"))
                let code = emit(["ok": result.success, "pdf": result.output.path, "log": URL(fileURLWithPath: output).appendingPathComponent("compiler.log").path, "diagnostics": TeXDiagnostics.parse(result.log).map { ["severity": String(describing: $0.severity), "message": $0.message, "file": $0.file ?? "", "line": $0.line ?? 0] as [String: Any] }]); return result.success ? code : 1
            case "writer-page", "writer-object", "writer-view", "documents", "submission-compare", "open", "status", "diagnostics", "read", "select", "replace", "save", "compile", "history", "transform", "rename", "export", "logs":
                let operation = command == "compile" && options.contains("--submission-check") ? "submission-check" : command
                var request = EditorBridge.Request(operation: operation, file: command == "open" ? options.first : option("--file"))
                request.target = option("--target").flatMap(UUID.init(uuidString:))
                request.zoom = option("--zoom").flatMap(Double.init); request.rulers = option("--rulers").map { $0 == "on" }; request.fit = options.contains("--fit")
                request.header = options.contains("--clear-header") ? "" : option("--header"); request.footer = options.contains("--clear-footer") ? "" : option("--footer")
                request.topLine = option("--top-line").map { $0 == "on" }; request.bottomLine = option("--bottom-line").map { $0 == "on" }; request.pageNumbers = option("--page-numbers").map { $0 == "on" }
                request.columns = option("--columns").flatMap(Int.init)
                request.object = option("--id").flatMap(UUID.init(uuidString:)); request.wrap = option("--wrap").map { $0 == "on" }; request.locked = option("--lock").map { $0 == "on" }
                request.action = option("--action"); request.name = option("--name"); request.kind = option("--kind"); request.output = option("--output")
                if command == "submission-compare", options.contains("--status") { request.kind = "status" }
                request.apply = options.contains("--apply"); request.scratch = options.contains("--scratch"); request.submissionCheck = options.contains("--submission-check"); request.expectedSHA256 = option("--expected-sha256")
                request.start = option("--start").flatMap(Int.init); request.length = option("--length").flatMap(Int.init)
                if command == "logs" { request.length = option("--tail").flatMap(Int.init) }
                if command == "replace" {
                    guard let path = option("--source-file"), path.hasPrefix("/"), let hash = option("--expected-sha256") else { throw Failure("Replace requires --source-file and --expected-sha256.") }
                    let data = try Data(contentsOf: URL(fileURLWithPath: path)); guard data.count <= 4_000_000, let source = String(data: data, encoding: .utf8) else { throw Failure("Source must be UTF-8 and at most 4 MB.") }
                    request.source = source; request.expectedSHA256 = hash
                }
                return try send(request)
            default: throw Failure("Unknown command. Use --cli help.")
            }
        } catch { return emit(["ok": false, "error": error.localizedDescription]) }
    }
    private static func send(_ request: EditorBridge.Request) throws -> Int32 {
    let folder = EditorBridge.directory
    guard FileManager.default.fileExists(atPath: folder.path) else { throw Failure("Start remile. before using live commands.") }
    let input = folder.appendingPathComponent(request.id.uuidString + ".request.json"), output = folder.appendingPathComponent(request.id.uuidString + ".response.json")
    defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
    try JSONEncoder().encode(request).write(to: input, options: [.atomic]); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
    let timeout: TimeInterval = request.operation == "overleaf" && request.action == "review" ? 120 : ["library-search", "reference-recognise"].contains(request.operation) ? 60 : 10
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: output.path) { let response = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any] ?? [:]; return emit(response) }
        Thread.sleep(forTimeInterval: 0.05)
    }
    throw Failure("The app did not respond. Close modal dialogues and try again.")
    }
    private final class CompressionReply: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<PDFCompressor.Result, Error>?
        var value: Result<PDFCompressor.Result, Error>? { lock.lock(); defer { lock.unlock() }; return result }
        func set(_ value: Result<PDFCompressor.Result, Error>) { lock.lock(); result = value; lock.unlock() }
    }
    private struct Failure: LocalizedError { let errorDescription: String?; init(_ message: String) { errorDescription = message } }
    private static func emit(_ value: [String: Any]) -> Int32 {
        let bytes = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(bytes); FileHandle.standardOutput.write(Data("\n".utf8)); return value["ok"] as? Bool == false ? 1 : 0
    }
}
