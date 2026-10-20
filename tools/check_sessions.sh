#!/bin/zsh
set -eu
project_directory="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="${1:?Provide the absolute model-check output directory}"
case "$check_directory" in /*) ;; *) print -u2 "The output directory must be absolute."; exit 1 ;; esac
[[ -f "$check_directory/threaded.pdf" ]] || { print -u2 "Run check_models.sh first."; exit 1; }
cat "$project_directory/Sources/Deerstalker/Assistant/AssistantPassage.swift" \
    "$project_directory/Sources/Deerstalker/PDF/PDFCitation.swift" \
    "$project_directory/Sources/Deerstalker/PDF/HighlightPalette.swift" \
    "$project_directory/Sources/Deerstalker/PDF/PDFReplyWriter.swift" \
    "$project_directory/Sources/Deerstalker/PDF/PDFCommentGraph.swift" \
    "$project_directory/Sources/Deerstalker/PDF/PDFNotes.swift" \
    "$project_directory/Sources/Deerstalker/PDF/PDFSession.swift" \
    "$project_directory/Tests/SessionChecks/main.swift" > "$check_directory/session-checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/session-checks.swift" "$check_directory"
