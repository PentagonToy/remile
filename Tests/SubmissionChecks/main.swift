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
let recoverable = source.replacingOccurrences(of: "\\cite{demo}.", with: "\\cite{demo}. \\UndefinedPreviewControl")
let recoverableBuffers = ["main.tex": recoverable, "refs.bib": bib]
let preview = try TeXCompileJob().run(root: root, main: "main.tex", buffers: recoverableBuffers, configuration: configuration, output: base.appendingPathComponent("error-preview"))
let previewText = preview.pdf.flatMap { PDFDocument(data: $0)?.string }
precondition(!preview.success && preview.log.contains("Undefined control sequence"))
precondition(previewText?.contains("Reference Test Book") == true && previewText?.contains("[?]") == false)
let strict = try TeXCompileJob().run(root: root, main: "main.tex", buffers: recoverableBuffers, configuration: configuration, output: base.appendingPathComponent("error-check"), checkProject: true)
precondition(!strict.success && strict.pdf == nil && strict.submissionIssue == .compiler)
print("Passed error preview: bibliography completes, PDF remains available, and the submission check still fails")
let bbl = try String(contentsOf: normal.output.deletingPathExtension().appendingPathExtension("bbl"), encoding: .utf8)
try bbl.write(to: root.appendingPathComponent("main.bbl"), atomically: true, encoding: .utf8)
let rejected = try TeXCompileJob().run(root: root, main: "main.tex", buffers: ["main.tex": source, "refs.bib": bib], configuration: configuration, output: base.appendingPathComponent("unembedded"), submissionCheck: true)
precondition(!rejected.success && rejected.log.contains("Unresolved citations"))
for path in ["refs.bib", "main.bbl", "stale.aux"] { precondition(!manager.fileExists(atPath: base.appendingPathComponent("unembedded/Source/" + path).path)) }
let embedded = try TeXSourceTools.inlineBibliography(source, bbl: bbl)
precondition(embedded.contains("\\begin{thebibliography}") && !embedded.contains("\\bibliography{") && !embedded.contains("\\bibliographystyle{"))
var alternateConfiguration = configuration
alternateConfiguration.engine = .xe
let passed = try TeXCompileJob().run(root: root, main: "main.tex", buffers: ["main.tex": embedded], configuration: alternateConfiguration, output: base.appendingPathComponent("embedded"), submissionCheck: true)
precondition(passed.success && passed.log.contains("Submission check passed") && passed.log.contains("This is pdfTeX"))
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

alternateConfiguration.engine = .lua
let comparison = try TeXSubmissionComparison.run(root: root, main: "main.tex", buffers: ["main.tex": source, "refs.bib": bib], configuration: alternateConfiguration, output: base.appendingPathComponent("comparison"), job: TeXCompileJob())
precondition(comparison.rows.map(\.state) == ["failed", "passed"])
precondition(comparison.embedded?.contains("\\begin{thebibliography}") == true)
precondition(comparison.rows.allSatisfy { $0.logPath != nil && !$0.log.isEmpty })
let preparationLog = try String(contentsOf: base.appendingPathComponent("comparison/Prepare/compiler.log"), encoding: .utf8)
precondition(preparationLog.contains("This is pdfTeX"))
let untouched = try String(contentsOf: root.appendingPathComponent("main.tex"), encoding: .utf8)
precondition(untouched == source)
let alreadyInline = try TeXSubmissionComparison.run(root: root, main: "main.tex", buffers: ["main.tex": embedded], configuration: configuration, output: base.appendingPathComponent("already-inline"), job: TeXCompileJob())
precondition(alreadyInline.rows.map(\.state) == ["passed", "passed"] && alreadyInline.embedded == nil)
print("Passed two-result comparison: current failure, embedded success, per-row logs, unchanged originals and already-inline source")

let recorded = try TeXSourceTools.inlineBibliography(source, bbl: bbl, keepOrigin: true)
let recordedOutput = try TeXCompileJob().run(root: root, main: "main.tex", buffers: ["main.tex": recorded], configuration: configuration, output: base.appendingPathComponent("recorded"), submissionCheck: true)
precondition(recordedOutput.success)
let restored = try TeXSourceTools.restoreBibliography(recorded)
precondition(restored.source == source && restored.references == ["refs.bib"])
let laterEdit = recorded.replacingOccurrences(of: "Reference test", with: "Later edit")
let restoredLaterEdit = try TeXSourceTools.restoreBibliography(laterEdit)
precondition(restoredLaterEdit.source == source.replacingOccurrences(of: "Reference test", with: "Later edit"))
let cleaned = try TeXSourceTools.removingAuthorNotes(recorded + "% Delete this note\n")
precondition(cleaned.source == recorded && cleaned.count == 1)
let altered = recorded.replacingOccurrences(of: "\\bibitem{demo}", with: "\\bibitem{changed}")
let missingStyle = recorded.split(separator: "\n", omittingEmptySubsequences: false)
    .filter { !$0.hasPrefix("% remile-bib:v1 style ") }.joined(separator: "\n")
for unavailable in [altered, missingStyle, embedded] {
    precondition((try? TeXSourceTools.restoreBibliography(unavailable)) == nil)
}
let recompiled = try TeXCompileJob().run(root: root, main: "main.tex", buffers: ["main.tex": restored.source, "refs.bib": bib], configuration: configuration, output: base.appendingPathComponent("restored"))
precondition(recompiled.success)
print("Passed reversible embedding: checked PDF, exact restore, later edits, note cleanup and changed-block rejection")

let currentRoot = base.appendingPathComponent("current-fixture")
try manager.createDirectory(at: currentRoot, withIntermediateDirectories: true)
try source.write(to: currentRoot.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
try bib.write(to: currentRoot.appendingPathComponent("refs.bib"), atomically: true, encoding: .utf8)
try "stale".write(to: currentRoot.appendingPathComponent("main.aux"), atomically: true, encoding: .utf8)
try "fixture".write(to: currentRoot.appendingPathComponent("support.bst"), atomically: true, encoding: .utf8)
func checkCurrent(_ label: String, source: String, configuration: TeXConfiguration = configuration) throws -> TeXSubmissionComparison.Row {
    let output = base.appendingPathComponent(label)
    let result = try TeXSubmissionComparison.run(root: currentRoot, main: "main.tex", buffers: ["main.tex": source, "refs.bib": bib], configuration: configuration, output: output, job: TeXCompileJob(), compareEmbedded: false)
    precondition(result.rows[1].state == "skipped" && result.embedded == nil)
    let snapshot = output.appendingPathComponent("Current/Source")
    precondition(manager.fileExists(atPath: snapshot.appendingPathComponent("refs.bib").path))
    precondition(manager.fileExists(atPath: snapshot.appendingPathComponent("support.bst").path))
    precondition(!manager.fileExists(atPath: snapshot.appendingPathComponent("main.aux").path))
    return result.rows[0]
}
let single = try checkCurrent("current-only", source: source)
precondition(single.state == "passed", single.log)
let biblatexSource = """
\\documentclass{article}
\\usepackage[backend=bibtex]{biblatex}
\\addbibresource{refs.bib}
\\begin{document}
\\cite{demo}
\\printbibliography
\\end{document}
"""
let biblatex = try checkCurrent("biblatex", source: biblatexSource)
precondition(biblatex.state == "passed", biblatex.log)
let invalid = source.replacingOccurrences(of: "Reference test", with: "\\notACommand")
let failed = try checkCurrent("syntax-error", source: invalid)
precondition(failed.issue == .compiler && failed.log.contains("Undefined control sequence"), failed.log)
let supplied = currentRoot.appendingPathComponent("main.bbl")
try bbl.write(to: supplied, atomically: true, encoding: .utf8)
let packaged = try checkCurrent("supplied-bbl", source: source)
precondition(packaged.state == "passed" && packaged.detail.contains("supplied .bbl"), packaged.log)
precondition(packaged.log.contains("without a bibliography processor") && !packaged.log.contains("applying rule 'bibtex"))
let changedCitation = source.replacingOccurrences(of: "\\cite{demo}", with: "\\cite{missing}")
let stale = try checkCurrent("stale-bbl", source: changedCitation)
precondition(stale.issue == .unresolved && !stale.log.contains("applying rule 'bibtex"), stale.log)
try manager.moveItem(at: supplied, to: currentRoot.appendingPathComponent("unrelated.bbl"))
let unused = try checkCurrent("unused-bbl", source: source)
precondition(unused.state == "passed", unused.log)
let escapedCurrent = try checkCurrent("current-external-bbl", source: external)
precondition(escapedCurrent.issue == .externalSource, escapedCurrent.log)
let afterChecks = try String(contentsOf: currentRoot.appendingPathComponent("main.tex"), encoding: .utf8)
precondition(afterChecks == source)
print("Passed current-file checks: BibTeX, biblatex, syntax errors, supplied and stale .bbl, external bibliography, and clean snapshots")
