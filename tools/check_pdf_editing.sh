#!/bin/zsh
set -eu
project_directory="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="${1:?Provide an absolute external output directory}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
cat "$project_directory/Sources/Remile/Assistant/AssistantPassage.swift" \
    "$project_directory/Sources/Remile/PDF/PDFCitation.swift" \
    "$project_directory/Sources/Remile/PDF/HighlightPalette.swift" \
    "$project_directory/Sources/Remile/PDF/PDFReplyWriter.swift" \
    "$project_directory/Sources/Remile/PDF/PDFCommentGraph.swift" \
    "$project_directory/Sources/Remile/PDF/PDFNotes.swift" \
    "$project_directory/Sources/Remile/PDF/PDFEditing.swift" \
    "$project_directory/Sources/Remile/PDF/PDFPageAssembly.swift" \
    "$project_directory/Sources/Remile/PDF/PDFPageSizing.swift" \
    "$project_directory/Sources/Remile/PDF/PDFSession.swift" \
    "$project_directory/Tests/PDFEditingChecks/main.swift" > "$check_directory/pdf-editing-checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/pdf-editing-checks.swift" "$check_directory"
