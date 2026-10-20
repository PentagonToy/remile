import Foundation
var passed = 0
func check(_ valid: Bool, _ name: String) { precondition(valid, name); passed += 1; print("PASS " + name) }
func complete(_ source: String) -> EditorCompletion.Context? { EditorCompletion.context(source, selection: NSRange(location: (source as NSString).length, length: 0), tex: false) }
check(complete("$$\nbe")?.items.first?.insertion == "\\begin{}", "bare begin in display maths")
check(complete("$$\n\\be")?.items.first?.insertion == "\\begin{}", "backslash begin in display maths")
check(complete("$$\n\\begin{al")?.items.contains { $0.insertion == "align}" } == true, "Markdown environment names")
let align = complete("한글 $$\nalign")?.items.first
check(align?.insertion == "\\begin{align}\n    \n\\end{align}", "paired environment with Unicode prefix")
check(align?.caret == 18, "caret inside environment")
check(complete("ordinary be") == nil, "no maths dropdown in prose")
check(complete("```tex\n$$\nbe") == nil, "no maths dropdown in fenced code")
check(complete("$$\n% be") == nil, "no completion in math comment")
check(complete("$\\alp")?.items.first?.insertion == "\\alpha", "existing symbol completion")
check(complete("$$\nfig") == nil, "no document environments in Markdown formulae")
let tableSource = "Intro\n| Label | Math |\n| :--- | ---: |\n| a\\|b | $\\alpha$ |\nEnd"
let table = MarkdownTable.parse(tableSource, selection: NSRange(location: 45, length: 0))!
check(table.cells[1][0] == "a|b", "escaped table separator")
check(table.markdown.contains("a\\|b") && table.markdown.contains("$\\alpha$"), "table preserves formula backslashes")
check(table.markdown.contains(":--- | ---:"), "table preserves alignment")
check((tableSource as NSString).substring(with: table.range).hasPrefix("| Label"), "table replaces only table source")
check(MarkdownTable.pasted("Name\tValue\nA\t2") == "| Name | Value |\n| --- | --- |\n| A | 2 |", "spreadsheet paste")
check(MarkdownTable.pasted("indent\ttext") == nil, "single line tab remains source")
check(MarkdownTable.pasted("a\tb\nc") == nil, "ragged clipboard remains source")
let spelling = "Prose mispelled $\\alpha$ \\begin{align} \\cite{myKey} `codeword`\n```\ncodeblock\n```"
let excluded = EditorSpellcheck.excluded(spelling), raw = spelling as NSString
check(EditorSpellcheck.accepts(raw.range(of: "mispelled"), excluded: excluded), "prose stays spellchecked")
for word in ["alpha", "align", "myKey", "codeword", "codeblock"] { check(!EditorSpellcheck.accepts(raw.range(of: word), excluded: excluded), "exclude syntax " + word) }

check(MarkdownTable.pasted("A\tB\n\"one\ntwo\"\t3")?.contains("one<br>two") == true, "quoted multiline spreadsheet cells")
check(MarkdownTable.pasted("A\tB\n\"unterminated\t3") == nil, "malformed quoted clipboard stays plain")
let closing = "$$\n\\begin{al}"
let closedContext = EditorCompletion.context(closing, selection: NSRange(location: (closing as NSString).length - 1, length: 0), tex: false)!
check(closedContext.range.length == 3 && closedContext.items.first?.insertion == "align}", "reuse existing closing brace without duplication")
let openings = EditorSpellcheck.sentenceOpenings("how to save a life.\nwhere did I go wrong?\n\n$$\nx=2\n$$\n\n`lowercase code`\n")
check(openings.count == 2, "capitalisation feedback excludes maths and code")
print("Passed \(passed) Markdown workflow checks")
