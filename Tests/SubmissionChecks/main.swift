import PDFKit

let base = URL(fileURLWithPath: CommandLine.arguments[1]), manager = FileManager.default
try manager.createDirectory(at: base, withIntermediateDirectories: true)
let root = base.appendingPathComponent("fixture")
try manager.createDirectory(at: root, withIntermediateDirectories: true)
let source = "\\documentclass{article}\n\\begin{document}\nReference test \\cite{demo}.\n\\bibliographystyle{plain}\n\\bibliography{refs}\n\\end{document}\n"
let bib = "@book{demo, author={Example, Alice}, title={Reference Test Book}, year={2020}, publisher={Example Press}}"
try source.write(to: root.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
try bib.write(to: root.appendingPathComponent("refs.bib"), atomically: true, encoding: .utf8)
try "stale".write(to: root.appendingPathComponent("stale.aux"), atomically: true, encoding: .utf8)
let configuration = TeXConfiguration(directory: "/Library/TeX/texbin", engine: .pdf)
let normal = try TeXCompileJob().run(root: root, main: "main.tex", buffers: ["main.tex": source], configuration: configuration, output: base.appendingPathComponent("normal"))
precondition(normal.success)
let bbl = try String(contentsOf: normal.output.deletingPathExtension().appendingPathExtension("bbl"), encoding: .utf8)
try bbl.write(to: root.appendingPathComponent("main.bbl"), atomically: true, encoding: .utf8)
let rejected = try TeXCompileJob().run(root: root, main: "main.tex", buffers: ["main.tex": source, "refs.bib": bib], configuration: configuration, output: base.appendingPathComponent("unembedded"), submissionCheck: true)
precondition(!rejected.success && rejected.log.contains("Unresolved citations"))
for path in ["refs.bib", "main.bbl", "stale.aux"] { precondition(!manager.fileExists(atPath: base.appendingPathComponent("unembedded/Source/" + path).path)) }
let embedded = try TeXSourceTools.inlineBibliography(source, bbl: bbl)
precondition(embedded.contains("\\begin{thebibliography}") && !embedded.contains("\\bibliography{") && !embedded.contains("\\bibliographystyle{"))
let passed = try TeXCompileJob().run(root: root, main: "main.tex", buffers: ["main.tex": embedded], configuration: configuration, output: base.appendingPathComponent("embedded"), submissionCheck: true)
precondition(passed.success && passed.log.contains("Submission check passed"))
let document = PDFDocument(data: passed.pdf!)!
precondition(document.pageCount == 1 && document.string?.contains("Reference Test Book") == true && document.string?.contains("[?]") == false)
let external = source.replacingOccurrences(of: "\\bibliography{refs}", with: "\\input{" + normal.output.deletingPathExtension().appendingPathExtension("bbl").path + "}")
let escaped = try TeXCompileJob().run(root: root, main: "main.tex", buffers: ["main.tex": external], configuration: configuration, output: base.appendingPathComponent("external-bbl"), submissionCheck: true)
precondition(!escaped.success && escaped.log.contains("A bibliography file was read"))
let original = try String(contentsOf: root.appendingPathComponent("main.tex"), encoding: .utf8)
precondition(original == source)
let noCite = source.replacingOccurrences(of: "Reference test \\cite{demo}.", with: "\\nocite{*}")
let missingList = try TeXCompileJob().run(root: root, main: "main.tex", buffers: ["main.tex": noCite], configuration: configuration, output: base.appendingPathComponent("nocite-missing-list"), submissionCheck: true)
precondition(!missingList.success)
print("Passed submission checks: normal BibTeX build, unembedded failure, cache/bibliography exclusion, embedding round trip, resolved PDF references and external-bbl rejection")

let comparison = try TeXSubmissionComparison.run(root: root, main: "main.tex", buffers: ["main.tex": source, "refs.bib": bib], configuration: configuration, output: base.appendingPathComponent("comparison"), job: TeXCompileJob())
precondition(comparison.rows.map(\.state) == ["failed", "passed"])
precondition(comparison.embedded?.contains("\\begin{thebibliography}") == true)
precondition(comparison.rows.allSatisfy { $0.logPath != nil && !$0.log.isEmpty })
let untouched = try String(contentsOf: root.appendingPathComponent("main.tex"), encoding: .utf8)
precondition(untouched == source)
let alreadyInline = try TeXSubmissionComparison.run(root: root, main: "main.tex", buffers: ["main.tex": embedded], configuration: configuration, output: base.appendingPathComponent("already-inline"), job: TeXCompileJob())
precondition(alreadyInline.rows.map(\.state) == ["passed", "passed"] && alreadyInline.embedded == nil)
print("Passed two-result comparison: current failure, embedded success, per-row logs, unchanged originals and already-inline source")
