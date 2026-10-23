import Foundation

/// Validate the command before file access or dispatch to the active editor.
enum EditorCLIArguments {
    struct Rule {
        var values: Set<String> = []
        var flags: Set<String> = []
        var paths: ClosedRange<Int> = 0...0
    }

    private static let rules: [String: Rule] = [
        "help": Rule(), "--help": Rule(), "version": Rule(), "--version": Rule(),
        "documents": Rule(), "doctor": Rule(), "status": Rule(), "diagnostics": Rule(), "save": Rule(), "history": Rule(),
        "read": Rule(values: ["--file"]), "select": Rule(values: ["--file"]),
        "logs": Rule(values: ["--tail"]),
        "open": Rule(paths: 1...1), "inspect": Rule(paths: 1...1),
        "build": Rule(values: ["--output", "--main"], flags: ["--scratch", "--submission-check"], paths: 1...1),
        "compile": Rule(flags: ["--scratch", "--submission-check"]),
        "submission-compare": Rule(flags: ["--status"]),
        "replace": Rule(values: ["--file", "--source-file", "--expected-sha256"]),
        "rename": Rule(values: ["--file", "--name", "--kind"]),
        "export": Rule(values: ["--kind", "--output"]),
        "transform": Rule(values: ["--action", "--file", "--start", "--length", "--expected-sha256"], flags: ["--apply"]),
        "review": Rule(values: ["--file", "--format", "--output"], flags: ["--run", "--stop", "--clear", "--criteria"], paths: 0...1),
        "pdf-read": Rule(values: ["--page", "--find", "--render"], paths: 0...1),
        "comments": Rule(values: ["--format", "--output"], paths: 0...1),
        "combine": Rule(values: ["--output"], paths: 2...Int.max),
        "compress": Rule(values: ["--output", "--quality"], flags: ["--grayscale"], paths: 1...1),
        "reference": Rule(values: ["--id", "--output", "--limit", "--offset", "--query", "--library", "--source-file", "--expected-revision", "--attachment", "--kind", "--page", "--start", "--length", "--expected-sha256"], flags: ["--trash"], paths: 1...1),
        "library-search": Rule(flags: ["--no-boost"], paths: 1...Int.max)
    ]

    static func validate(command: String, options: [String]) throws {
        guard var rule = rules[command] else { throw Failure("Unknown command. Use --cli help.") }
        if ["status", "diagnostics", "read", "select", "replace", "save", "compile", "history", "transform", "rename", "export", "logs", "submission-compare", "review", "pdf-read", "comments"].contains(command) { rule.values.insert("--target") }
        var seen: Set<String> = [], positionals: [String] = [], values: [String: String] = [:], index = 0
        while index < options.count {
            let argument = options[index]
            if rule.values.contains(argument) || rule.flags.contains(argument) {
                guard seen.insert(argument).inserted else { throw Failure("Duplicate option: \(argument).") }
                if rule.values.contains(argument) {
                    guard index + 1 < options.count, !options[index + 1].hasPrefix("--"), !options[index + 1].isEmpty else { throw Failure("Provide a value for \(argument).") }
                    values[argument] = options[index + 1]
                    index += 1
                }
            } else if argument.hasPrefix("--") {
                throw Failure("Unknown option: \(argument).")
            } else {
                positionals.append(argument)
                // Existing handlers use the first argument as their document path.
                if command != "library-search", positionals.count == 1, index != 0 { throw Failure("Place the input path before options.") }
            }
            index += 1
        }
        guard rule.paths.contains(positionals.count) else { throw Failure("Provide the expected input path or query. Use --cli help.") }
        if command != "library-search", command != "reference", positionals.contains(where: { !$0.hasPrefix("/") }) { throw Failure("Provide absolute input paths.") }
        if values["--target"] != nil, !positionals.isEmpty { throw Failure("Choose a document path or --target, not both.") }
        if command == "reference" {
            let allowed: Set<String>
            switch positionals.first {
            case "libraries": allowed = []
            case "list": allowed = ["--limit", "--offset", "--query", "--trash", "--library"]
            case "evidence": allowed = ["--id", "--attachment", "--page"]; guard values["--id"] != nil, values["--attachment"] != nil else { throw Failure("Provide --id and --attachment.") }
            case "passages": allowed = ["--id"]; guard values["--id"] != nil else { throw Failure("Provide --id for saved passages.") }
            case "save-passage":
                allowed = ["--id", "--attachment", "--page", "--start", "--length", "--expected-sha256"]
                guard allowed.allSatisfy({ values[$0] != nil }) else { throw Failure("Provide reference, attachment, PDF hash, page and UTF-16 range.") }
            case "suggest": allowed = ["--query", "--library", "--limit"]; guard values["--library"] != nil else { throw Failure("Choose --library for citation suggestions.") }
            case "citation": allowed = ["--id", "--kind"]; guard values["--id"] != nil, ["latex", "markdown"].contains(values["--kind"] ?? "latex") else { throw Failure("Provide --id and --kind latex or markdown.") }
            case "show": allowed = ["--id"]; guard values["--id"] != nil else { throw Failure("Provide --id for reference show.") }
            case "export": allowed = ["--id", "--output", "--library"]
            case "import": allowed = ["--library", "--source-file"]; guard values["--library"] != nil && values["--source-file"] != nil else { throw Failure("Import requires --library and --source-file.") }
            case "update", "attach": allowed = ["--id", "--expected-revision", "--source-file"]; guard values["--id"] != nil && values["--expected-revision"] != nil && values["--source-file"] != nil else { throw Failure("Provide --id, --expected-revision and --source-file.") }
            case "trash", "restore", "regenerate-key": allowed = ["--id", "--expected-revision"]; guard values["--id"] != nil && values["--expected-revision"] != nil else { throw Failure("Provide --id and --expected-revision.") }
            case "detach": allowed = ["--id", "--expected-revision", "--attachment"]; guard values["--id"] != nil && values["--expected-revision"] != nil && values["--attachment"] != nil else { throw Failure("Provide --id, --expected-revision and --attachment.") }
            default: throw Failure("Use reference libraries, list, show, export, import, update, attach, detach, trash, restore or regenerate-key.")
            }
            guard seen.isSubset(of: allowed) else { throw Failure("This option is not supported by the reference action.") }
            if let id = values["--id"], UUID(uuidString: id) == nil { throw Failure("Use a valid reference ID.") }
            if let id = values["--library"], UUID(uuidString: id) == nil { throw Failure("Use a valid library ID.") }
            if let limit = values["--limit"], Int(limit).map({ (1...200).contains($0) }) != true { throw Failure("Use --limit between 1 and 200.") }
            if let offset = values["--offset"], Int(offset).map({ $0 >= 0 }) != true { throw Failure("Use a non-negative --offset.") }
        }
        for key in ["--target", "--expected-revision", "--attachment"] {
            if let value = values[key], UUID(uuidString: value) == nil { throw Failure("Use a valid UUID for \(key).") }
        }
        if let source = values["--source-file"], !source.hasPrefix("/") { throw Failure("Use an absolute --source-file path.") }
        for key in ["--start", "--length", "--page", "--tail"] {
            if let value = values[key] {
                guard let number = Int(value), number >= (key == "--page" || key == "--tail" ? 1 : 0) else { throw Failure("Provide a valid \(key == "--page" || key == "--tail" ? "positive" : "non-negative") integer for \(key).") }
            }
        }
        if values["--length"] != nil, values["--start"] == nil { throw Failure("Use --start with --length.") }
        if let start = values["--start"].flatMap(Int.init), let length = values["--length"].flatMap(Int.init), start.addingReportingOverflow(length).overflow { throw Failure("The source range is too large.") }
        if let hash = values["--expected-sha256"], hash.count != 64 || !hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) { throw Failure("Use the lowercase SHA-256 returned by read.") }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
