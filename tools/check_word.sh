#!/bin/zsh
set -eu
project_directory="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="${1:?Provide an absolute output directory under Agents/Repository containing Rich.docx and Long.docx}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
[[ -f "$check_directory/Rich.docx" && -f "$check_directory/Layout.docx" && -f "$check_directory/MathSemantics.docx" ]] || { print -u2 "Generate fixtures with make_fixture.py, make_layout_fixture.py and make_math_fixture.py first."; exit 1; }
mkdir -p "$check_directory/module-cache"
cat "$project_directory/Sources/Remile/Markdown/MarkdownBlocks.swift" \
    "$project_directory/Sources/Remile/Markdown/MathMarkup.swift" \
    "$project_directory/Sources/Remile/Markdown/MarkdownHTML.swift" \
    "$project_directory/Sources/Remile/Markdown/MarkdownPDF.swift" \
    "$project_directory/Sources/Remile/Convert/WordArchive.swift" \
    "$project_directory/Sources/Remile/Convert/WordXML.swift" \
    "$project_directory/Sources/Remile/Convert/WordMath.swift" \
    "$project_directory/Sources/Remile/Convert/WordArt.swift" \
    "$project_directory/Sources/Remile/Convert/WordShape.swift" \
    "$project_directory/Sources/Remile/Convert/WordImages.swift" \
    "$project_directory/Sources/Remile/Convert/WordFurniture.swift" \
    "$project_directory/Sources/Remile/Convert/WordPDF.swift" \
    "$project_directory/Sources/Remile/Convert/DocumentConverter.swift" \
    "$project_directory/Tests/WordChecks/main.swift" > "$check_directory/word-checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/word-checks.swift" "$check_directory"
