#!/bin/zsh
set -eu
project_directory="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="${1:?Provide an absolute directory under Agents/Repository for compression checks}"
[[ "$check_directory" = /* ]] || exit 1
mkdir -p "$check_directory/module-cache"
cat "$project_directory/Sources/Deerstalker/Markdown/MarkdownBlocks.swift" \
    "$project_directory/Sources/Deerstalker/Markdown/MathMarkup.swift" \
    "$project_directory/Sources/Deerstalker/Markdown/MarkdownHTML.swift" \
    "$project_directory/Sources/Deerstalker/Markdown/MarkdownPDF.swift" \
    "$project_directory/Sources/Deerstalker/Convert/WordArchive.swift" \
    "$project_directory/Sources/Deerstalker/Convert/WordXML.swift" \
    "$project_directory/Sources/Deerstalker/Convert/WordMath.swift" \
    "$project_directory/Sources/Deerstalker/Convert/WordArt.swift" \
    "$project_directory/Sources/Deerstalker/Convert/WordShape.swift" \
    "$project_directory/Sources/Deerstalker/Convert/WordImages.swift" \
    "$project_directory/Sources/Deerstalker/Convert/WordFurniture.swift" \
    "$project_directory/Sources/Deerstalker/Convert/WordPDF.swift" \
    "$project_directory/Sources/Deerstalker/Convert/DocumentConverter.swift" \
    "$project_directory/Sources/Deerstalker/Convert/PDFCompressor.swift" \
    "$project_directory/Tests/CompressionChecks/main.swift" > "$check_directory/compression-checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/compression-checks.swift" "$check_directory"
