import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message); checks += 1 }
let text = "\\section{Heading} % comment\nPrice \\% escaped\n\\\\% comment after a line break\n$y &= 2$"
let tokens = TeXSyntax.tokens(text, range: NSRange(location: 0, length: (text as NSString).length))
expect(tokens.filter { $0.kind == .comment }.count == 2, "Escaped percent is not a comment; even backslashes allow a comment")
expect(tokens.contains { $0.kind == .command && (text as NSString).substring(with: $0.range) == "\\section" }, "TeX commands receive syntax attributes")
expect(TeXEditorTheme.allCases.count == 5, "Five editor palettes")
let log = "./setup/setting.tex:9: LaTeX Error: Option clash for package biblatex.\n\nLaTeX Warning: Citation undefined on input line 23.\n\nLaTeX Warning: Citation undefined on input line 23.\n"
let diagnostics = TeXDiagnostics.parse(log)
expect(TeXDiagnostics.logSeverity([]) == nil, "Clean build has no terminal dot")
expect(TeXDiagnostics.logSeverity([TeXDiagnostic(id: 0, severity: .info, message: "Info", file: nil, line: nil)]) == nil, "Information does not create a warning dot")
expect(TeXDiagnostics.logSeverity(TeXDiagnostics.parse("LaTeX Warning: Citation undefined.\n")) == .warning, "Warnings use the warning dot")
expect(TeXDiagnostics.logSeverity(Array(diagnostics.reversed())) == .error, "Errors take precedence regardless of order")
expect(TeXDiagnostics.logSeverity([], failed: true) == .error, "Failed builds remain visible without parsed errors")
expect(diagnostics.filter { $0.severity == .error }.count == 1, "Fatal file-line error classified")
expect(diagnostics.filter { $0.severity == .warning }.count == 1, "Repeated warning deduplicated")
expect(diagnostics.first?.file == "./setup/setting.tex" && diagnostics.first?.line == 9, "Clickable location retained")
let passes = TeXDiagnostics.parse("This is XeTeX\nLaTeX Warning: Citation missing.\n\n[10] Biber.pm:130> WARN - Non-integer year.\nThis is XeTeX\nOutput written on main.xdv\n")
expect(!passes.contains { $0.message.contains("Citation missing") }, "Resolved earlier-pass warnings are hidden")
expect(passes.contains { $0.message.contains("Non-integer year") }, "Bibliography warnings survive the final TeX pass")
let fields = TeXSync.fields("SyncTeX result begin\nOutput:first.pdf\nPage:4\nx:10\ny:20\nOutput:second.pdf\nPage:9\nx:30\ny:40\nSyncTeX result end")
expect(fields["Page"] == "4" && fields["x"] == "10", "Closest SyncTeX candidate retained")
if CommandLine.arguments.count > 1 {
    // Optional integration check uses an existing compiled snapshot, without compiling or saving it.
    let root = URL(fileURLWithPath: CommandLine.arguments[1]), file = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "contents/2-problem.tex"
    let line = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 22
    let source = root.appendingPathComponent("Source")
    let build = TeXBuild(pdf: root.appendingPathComponent("Build/main.pdf"), source: source, executable: URL(fileURLWithPath: "/Library/TeX/texbin/synctex"), buffers: [file: try String(contentsOf: source.appendingPathComponent(file), encoding: .utf8)], main: "main.tex")
    setenv("SYNCTEX_EDITOR", "/usr/bin/false", 1)
    let pdf = try TeXSync.forward(build, file: file, line: line)
    let code = try TeXSync.reverse(build, location: pdf)
    expect(code.file == file && abs(code.line - line) <= 5, "Actual forward/reverse mapping returns nearby source without invoking an external editor")
    print("SyncTeX:", pdf, "→", code)
}
print("Passed \(checks) TeX workspace checks")

expect(TeXMainDocument.choose(sources: ["main.tex": "documentclass{article}"], saved: nil) == "main.tex", "A missing command backslash cannot prevent opening")
expect(TeXMainDocument.choose(sources: ["main.tex": "", "template.tex": "\\documentclass{book}"], saved: nil) == "main.tex", "An empty main document opens before an unrelated template")
expect(TeXMainDocument.choose(sources: ["draft.tex": "broken", "main.tex": ""], saved: "draft.tex") == "draft.tex", "A saved main document remains editable despite syntax errors")
expect(TeXMainDocument.choose(sources: ["notes.tex": "\\section{Notes}", "chapter/a.tex": ""], saved: "missing.tex") == "notes.tex", "A project without a class declaration uses a stable source fallback")
expect(TeXMainDocument.choose(sources: ["DRAFT.TEX": ""], saved: nil) == "DRAFT.TEX", "Uppercase TeX extensions are editable")
expect(TeXMainDocument.choose(sources: ["refs.bib": ""], saved: nil) == nil, "A bibliography alone is not misidentified as a TeX source")
print("Passed \(checks) TeX workspace checks including broken sources")

let preciseSource = "\\documentclass{article}\n\\begin{document}\n\\rev{Earlier results are discussed here. They also assessed transfer to an unseen case at a higher Karlovitz number, both without retraining and with limited-data fine-tuning.}\n\\end{document}"
let hintText = "They also assessed transfer to an unseen case at a higher Karlovitz number, both without retraining and with limited-data fine-tuning."
let wordOffset = (hintText as NSString).range(of: "number").location
let near = TeXSync.SourceLocation(file: "main.tex", line: 2)
let precise = TeXSync.refine(near, source: preciseSource, hint: .init(text: hintText, offset: wordOffset))
expect(precise.range != nil && (preciseSource as NSString).substring(with: precise.range!) == "number", "PDF context refines a long macro-wrapped source line to its clicked word")
let repeatedSource = preciseSource + "\n" + preciseSource
expect(TeXSync.refine(near, source: repeatedSource, hint: .init(text: hintText, offset: wordOffset)).range == nil, "Repeated equally strong contexts retain SyncTeX line fallback")
expect(TeXSync.refine(near, source: preciseSource, hint: .init(text: "number", offset: 0)).range == nil, "A common word without context is not enough")
expect(TeXSync.refine(near, source: preciseSource, hint: nil) == near, "Missing PDF text retains existing navigation")
let unicodeSource = "é 😀 " + preciseSource
let unicodeRefined = TeXSync.refine(TeXSync.SourceLocation(file: "main.tex", line: 0), source: unicodeSource, hint: .init(text: hintText, offset: wordOffset))
expect(unicodeRefined.range != nil && (unicodeSource as NSString).substring(with: unicodeRefined.range!) == "number", "Refined offsets preserve UTF-16 positions after emoji")
print("Passed \(checks) TeX workspace checks including bounded text refinement")

let farAway = String(repeating: "padding ", count: 4000) + preciseSource
expect(TeXSync.refine(.init(file: "main.tex", line: 0), source: farAway, hint: .init(text: hintText, offset: wordOffset)).range == nil, "Refinement does not search distant document text beyond its fixed window")
print("Passed \(checks) TeX workspace checks including refinement bounds")
