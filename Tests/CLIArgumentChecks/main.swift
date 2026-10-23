import Foundation

var passed = 0
func accepts(_ command: String, _ options: [String] = []) throws {
    try EditorCLIArguments.validate(command: command, options: options)
    passed += 1
}
func rejects(_ command: String, _ options: [String]) {
    do {
        try EditorCLIArguments.validate(command: command, options: options)
        fatalError("Accepted invalid arguments: \(command) \(options)")
    } catch { passed += 1 }
}

// A malformed range must never become an unrestricted edit of the active document.
let hash = String(repeating: "a", count: 64)
try accepts("transform", ["--action", "indent", "--start", "0", "--length", "12", "--apply", "--expected-sha256", hash])
rejects("transform", ["--action", "indent", "--start", "oops", "--apply", "--expected-sha256", hash])
rejects("transform", ["--action", "indent", "--start", "0", "--length", "oops"])
rejects("transform", ["--length", "12"])
rejects("transform", ["--start", "-1"])
rejects("transform", ["--start", String(Int.max), "--length", "1"])
rejects("replace", ["--source-file", "/tmp/source", "--expected-sha256", "bad-hash"])
rejects("replace", ["--source-file", "--expected-sha256", hash])
rejects("replace", ["--file", "one.tex", "--file", "two.tex"])
rejects("save", ["--fiel", "main.tex"])
rejects("compile", ["--scratch", "--scratch"])
rejects("logs", ["--tail", "oops"])
rejects("logs", ["--tail", "0"])
rejects("pdf-read", ["--page", "0"])
rejects("pdf-read", ["--page"])
rejects("pdf-read", ["--page", "9999999999999999999999999"])
rejects("pdf-read", ["--page", "1", "/tmp/one.pdf"])
rejects("comments", ["relative.pdf"])
rejects("open", [])
rejects("open", ["/tmp/one", "/tmp/two"])
rejects("build", ["/tmp/project", "--ouput", "/tmp/output"])
rejects("library-search", ["--no-boost"])
rejects("library-search", ["question", "--no-bost"])
rejects("status", ["ignored"])
rejects("unknown", [])
try accepts("pdf-read", ["/tmp/a file.pdf", "--page", "2", "--find", "a word"])
try accepts("read", ["--file", "contents/a file.tex"])
try accepts("replace", ["--source-file", "/tmp/source", "--expected-sha256", hash])
try accepts("library-search", ["a question", "--no-boost"])
try accepts("library-search", ["--no-boost", "a", "question"])
try accepts("combine", ["/tmp/one.pdf", "--output", "/tmp/out.pdf", "/tmp/two.pdf"])
try accepts("build", ["/tmp/project", "--output", "/tmp/result", "--main", "main.tex", "--submission-check"])
try accepts("review", ["/tmp/project", "--format", "json"])
try accepts("review", ["--criteria"])
try accepts("compile", ["--submission-check", "--scratch"])
try accepts("transform", ["--action", "indent", "--start", "0"])
for command in ["help", "--help", "version", "--version", "doctor", "status", "diagnostics", "save", "history"] { try accepts(command) }
print("Passed \(passed) CLI argument checks.")

let target = UUID().uuidString
try accepts("documents")
try accepts("read", ["--target", target, "--file", "main.tex"])
try accepts("replace", ["--target", target, "--source-file", "/tmp/source", "--expected-sha256", hash])
rejects("read", ["--target", "invalid"])
rejects("documents", ["--target", target])
try accepts("reference", ["import", "--library", target, "--source-file", "/tmp/input.bib"])
try accepts("reference", ["update", "--id", target, "--expected-revision", target, "--source-file", "/tmp/input.bib"])
rejects("reference", ["update", "--id", target, "--source-file", "/tmp/input.bib"])
rejects("reference", ["trash", "--id", target])
rejects("reference", ["import", "--library", target, "--source-file", "relative.bib"])
print("Passed \(passed) CLI argument checks including explicit targets and revision-checked writes.")
for command in ["review", "pdf-read", "comments"] {
    try accepts(command, ["--target", target])
    rejects(command, ["/tmp/project", "--target", target])
}
print("Passed \(passed) CLI argument checks including offline-path/target ambiguity rejection.")
