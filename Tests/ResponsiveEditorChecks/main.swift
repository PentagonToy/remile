var passed = 0
func check(_ test: Bool, _ label: String) { precondition(test, label); passed += 1; print("PASS " + label) }
let text = "\\caption{Keep this caption}\n% TODO remove me\nText% author note\n\\% literal\n% !TEX program = xelatex\n\\begin{verbatim}\n% literal example\n\\end{verbatim}\n"
let stripped = try TeXSourceTools.removingAuthorNotes(text)
check(stripped.count == 2, "remove author notes only")
check(stripped.source.contains("\\caption{Keep this caption}"), "preserve figure captions")
check(stripped.source.contains("Text%\n"), "preserve inline TeX spacing marker")
check(stripped.source.contains("% !TEX program"), "preserve engine directive")
check(stripped.source.contains("% literal example"), "preserve verbatim")
check(stripped.source.contains("\\% literal"), "preserve escaped percent")
let full = NSRange(location: 0, length: 5)
let comment = EditorSourceEditing.toggleComment("a\n  b", selection: full)!
check(comment.text == "% a\n  % b", "comment preserves indentation")
let uncomment = EditorSourceEditing.toggleComment(comment.text, selection: NSRange(location: 0, length: (comment.text as NSString).length))!
check(uncomment.text == "a\n  b", "comment toggle round trip")
let indent = EditorSourceEditing.indent("one\ntwo\n", selection: NSRange(location: 0, length: 8), reverse: false)!
check(indent.text == "    one\n    two\n", "block indent")
check(EditorSourceEditing.indent(indent.text, selection: NSRange(location: 0, length: (indent.text as NSString).length), reverse: true)!.text == "one\ntwo\n", "block outdent")
check(EditorSourceEditing.indent("hello", selection: NSRange(location: 2, length: 0), reverse: false)!.text == "    ", "Tab inserts source spaces")
let item = EditorCompletion.context("it", selection: NSRange(location: 2, length: 0), tex: true)!
check(item.items.first?.insertion == "\\item ", "item is first")
check(item.items.allSatisfy { !$0.label.contains("environment") }, "clear candidate labels")
check(EditorCompletion.context("\\begin{al", selection: NSRange(location: 9, length: 0), tex: true)?.items.first?.insertion == "align}", "begin environment completion")
let bbl = "\\begin{thebibliography}{1}\\bibitem{x} Example.\\end{thebibliography}"
check(try TeXSourceTools.inlineBibliography("\\bibliographystyle{plain}\n\\bibliography{refs}", bbl: bbl).contains(bbl), "submission embedding remains supported")
print("Passed \(passed) responsive editor checks")
