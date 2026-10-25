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
 let result = index.context(q, selection: caret(q), file: "main.tex", paths: files, buffers: [:])!
 check(result.items.count == 2 && result.items.allSatisfy { $0.insertion.hasSuffix(".pdf") }, "Graphics names use the existing project tree")
 let ref = "\\ref{fig:"
 var buffers = ["main.tex":"\\label{fig:rate}\n% \\label{fig:hidden}"]
 check(index.context(ref, selection: caret(ref), file: "main.tex", paths: files, buffers: buffers)!.items.count == 1, "Label suggestions exclude comments")
 buffers["main.tex"] = "\\label{fig:new}"
 check(index.context(ref, selection: caret(ref), file: "main.tex", paths: files, buffers: buffers)!.items.first!.insertion == "fig:new", "Changed source invalidates old labels")
 check(index.context("ordinary text", selection: caret("ordinary text"), file: "main.tex", paths: files, buffers: buffers) == nil, "Ordinary typing skips project scans")
 print("\(checks) editor checks passed"); exit(0)
}
RunLoop.main.run()
