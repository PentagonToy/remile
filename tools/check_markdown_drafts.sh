#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an absolute external output directory for isolated draft checks}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
{
    for file in App/StorageFileAccess Assistant/AssistantPassage PDF/PDFCitation PDF/HighlightPalette PDF/PDFReplyWriter PDF/PDFFormPreservation PDF/PDFSignedAnnotations PDF/PDFCommentGraph PDF/PDFCommentExport PDF/PDFNotes PDF/PDFEditing PDF/PDFPageAssembly PDF/PDFPageSizing PDF/PDFDrawing PDF/PDFEditProtection PDF/PDFSession Markdown/EditorProvenance Documents/ReadingDocument; do
        cat "$project_directory/Sources/Remile/$file.swift"
    done
    sed '/^struct ReadingShell/,$d' "$project_directory/Sources/Remile/Documents/ReadingSession.swift"
    cat "$project_directory/Tests/MarkdownDraftChecks/main.swift"
} > "$check_directory/markdown-draft-checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/markdown-draft-checks.swift" "$check_directory"
