import AppKit

var checks = 0
func check(_ ok: Bool, _ message: String) { precondition(ok, message); checks += 1; print("PASS: " + message) }
func caret(_ s: String) -> NSRange { NSRange(location: (s as NSString).length, length: 0) }
Task { @MainActor in
 for env in ["itemize", "align", "figure", "equation*"] {
  let s = "  \\begin{" + env
  let c = EditorCompletion.closeEnvironment(s, selection: caret(s))!
  check(c.text.contains("\\end{" + env + "}"), "Typed closing brace pairs " + env)
 }
 let completed = "\\begin{item"
 let items = EditorCompletion.context(completed, selection: caret(completed), tex: true)!.items
 check(items.first!.insertion.contains("\\end{itemize}") && items.first!.insertion.contains("\\item "), "Accepting an environment suggestion inserts its body and end")
 let paired = "\\begin{align\n\\end{align}"
 check(EditorCompletion.closeEnvironment(paired, selection: NSRange(location: 12, length: 0)) == nil, "An existing end is not duplicated")
 let index = TeXLocalCompletion()
 let files = ["fig_method_temperature.pdf", "fig_method_rate.pdf", "main.tex"]
 let q = "\\includegraphics[width=0.47\\textwidth]{fig_"
 let result = await index.context(q, selection: caret(q), file: "main.tex", paths: files, buffers: [:])!
 check(result.items.count == 2 && result.items.allSatisfy { $0.insertion.hasSuffix(".pdf") }, "Graphics names use the existing project tree")
 let ref = "\\ref{fig:"
 var buffers = ["main.tex":"\\label{fig:rate}\n% \\label{fig:hidden}"]
 check(await index.context(ref, selection: caret(ref), file: "main.tex", paths: files, buffers: buffers)!.items.count == 1, "Label suggestions exclude comments")
 buffers["main.tex"] = "\\label{fig:new}"
 check(await index.context(ref, selection: caret(ref), file: "main.tex", paths: files, buffers: buffers)!.items.first!.insertion == "fig:new", "Changed source invalidates old labels")
 check(await index.context("ordinary text", selection: caret("ordinary text"), file: "main.tex", paths: files, buffers: buffers) == nil, "Ordinary typing skips project scans")

 let local = TeXLocalCompletion()
 let sources = ["defs.tex": #"\newcommand{\velocity}[2]{#1/#2}"# + "\n" + #"\DeclareMathOperator{\argbest}{argbest}"# + "\n" + #"\newenvironment{proofbox}{}{}"# + "\n" + #"\% literal percent \label{eq:escaped}"#]
 let custom = #"\vel"#
 let candidate = await local.context(custom, selection: caret(custom), file: "main.tex", paths: [], buffers: sources)!.items.first!
 check(candidate.insertion == #"\velocity{}{}"# && candidate.caret == 10, "Project commands preserve arguments and put the caret in the first slot")
 let prepared = await local.preparations
 _ = await local.context(custom, selection: caret(custom), file: "main.tex", paths: [], buffers: sources)
 check(await local.preparations == prepared, "Unchanged command definitions reuse the bounded project index")
 let escaped = #"\ref{eq:"#
 check(await local.context(escaped, selection: caret(escaped), file: "main.tex", paths: [], buffers: sources)!.items.first!.insertion == "eq:escaped", "Escaped percent signs do not hide later labels")
 let package = #"\usepackage{amsmath,gra"#
 check(await local.context(package, selection: caret(package), file: "main.tex", paths: [], buffers: [:])!.items.first!.insertion == "graphicx", "Comma-separated package suggestions replace only the active name")
 let bib = #"\bibliography{ref"#
 check(await local.context(bib, selection: caret(bib), file: "main.tex", paths: ["references.bib"], buffers: [:])!.items.first!.insertion == "references", "Bibliography names omit the extension for the legacy command")
 let environment = #"\begin{proof"#
 let block = await local.context(environment, selection: caret(environment), file: "main.tex", paths: [], buffers: sources)!.items.first!
 check(block.insertion.contains(#"\end{proofbox}"#), "Project-defined environments receive a matching end")
 check(EditorCompletion.context("ordinary theta prose", selection: caret("ordinary theta prose"), tex: true) == nil, "Ordinary prose does not trigger command suggestions")
 let command = #"\subsub"#
 check(EditorCompletion.context(command, selection: caret(command), tex: true)!.items.contains { $0.insertion == #"\subsubsection{}"# }, "Common section commands are available locally")
 let incomplete = #"\sec{Existing}"#
 let section = EditorCompletion.context(incomplete, selection: NSRange(location: 4, length: 0), tex: true)!.items.first { $0.label == #"\section{}"# }!
 check(section.insertion == #"\section"# && section.caret == 9, "Existing arguments are not duplicated by command completion")
 let explicit = #"\p"#
 check(EditorCompletion.context(explicit, selection: caret(explicit), tex: true, explicit: true) != nil, "Explicit completion accepts a single-letter command prefix")
 let longSource = String(repeating: "x", count: 1_000_000) + "\n" + #"\label{beyond:budget}"#
 let beyond = #"\ref{beyond:"#
 check(await local.context(beyond, selection: caret(beyond), file: "big.tex", paths: [], buffers: ["big.tex":longSource]) == nil, "Project suggestions respect the per-file parsing budget")
 print("\(checks) editor checks passed"); exit(0)
}
RunLoop.main.run()
