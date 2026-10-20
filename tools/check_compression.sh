#!/bin/zsh
set -eu
project_directory="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="${1:?Provide an absolute directory under Agents/Repository for compression checks}"
[[ "$check_directory" = /* ]] || exit 1
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
    "$project_directory/Sources/Remile/Convert/PDFCompressor.swift" \
    "$project_directory/Tests/CompressionChecks/main.swift" > "$check_directory/compression-checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/compression-checks.swift" "$check_directory"
