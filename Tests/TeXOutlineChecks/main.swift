let sources = [
    "main.tex": "\\documentclass{article}\n\\input{chapters/one}\n% \\input{ignored}\n\\include{two}\n\\input{../outside}\n\\section{End}",
    "chapters/one.tex": "\\section{First}\n\\input{detail}\n\\input{main}",
    "chapters/detail.tex": "\\subsection{Detail}",
    "two.tex": "\\section{Second}\n\\input{chapters/one}",
    "ignored.tex": "\\section{Hidden}",
    "../outside.tex": "\\section{Outside}"
]
let outline = TeXOutlineItem.project(sources, main: "main.tex")
precondition(outline.map(\.title) == ["First", "Detail", "Second", "End"], "Include order, comments, cycles and duplicate includes")
precondition(outline[1].file == "chapters/detail.tex" && outline[1].line == 0, "Nested relative source location")
precondition(outline[1].level == 1, "Section hierarchy")
precondition(Set(outline.map(\.id)).count == outline.count, "Identical line numbers in different files remain unique")
precondition(TeXOutlineItem.project(sources, main: "missing.tex").isEmpty)
let changed = sources.merging(["two.tex": "\\section{Unsaved}"]) { _, new in new }
precondition(TeXOutlineItem.project(changed, main: "main.tex")[2].title == "Unsaved", "Outline follows unsaved buffers")
precondition(TeXOutlineItem.project(["main.tex": "\\input{\\dynamic}"], main: "main.tex").isEmpty, "Dynamic TeX paths are not evaluated")
print("Passed 7 project outline checks")
