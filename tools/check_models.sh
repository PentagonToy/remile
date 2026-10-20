#!/bin/zsh
set -eu

project_directory="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="${1:?Provide an absolute output directory under Agents/Repository}"
case "$check_directory" in
    /*) ;;
    *) print -u2 "The output directory must be absolute."; exit 1 ;;
esac
mkdir -p "$check_directory/module-cache"
cat "$project_directory/Sources/Remile/PDF/PDFReplyWriter.swift" \
    "$project_directory/Sources/Remile/PDF/PDFCommentGraph.swift" \
    "$project_directory/Sources/Remile/PDF/PDFNotes.swift" \
    "$project_directory/Sources/Remile/Markdown/MarkdownBlocks.swift" \
    "$project_directory/Tests/ModelChecks/main.swift" > "$check_directory/model-checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/model-checks.swift" "$check_directory"
