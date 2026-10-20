#!/bin/zsh
set -eu
project_directory="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="${1:?Provide an absolute output directory under Agents/Repository containing Simple.docx}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
[[ -f "$check_directory/Simple.docx" ]] || { print -u2 "Provide an independently generated Simple.docx fixture."; exit 1; }
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
    "$project_directory/Tests/ConversionChecks/main.swift" > "$check_directory/conversion-checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/conversion-checks.swift" "$check_directory"
