#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an absolute external output directory containing signature fixtures}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
{
    for file in App/StorageLocation Documents/SourceDigest Markdown/EditorEditMarks App/StorageFileAccess Assistant/AssistantPassage PDF/PDFCitation PDF/HighlightPalette PDF/PDFReplyWriter PDF/PDFFormPreservation PDF/PDFSignedAnnotations PDF/PDFCommentGraph PDF/PDFCommentExport PDF/PDFSelectionText PDF/PDFNotes PDF/PDFEditing PDF/PDFPageAssembly PDF/PDFPageSizing PDF/PDFDrawing PDF/PDFReadingPosition PDF/SearchExcerpt PDF/PDFSession Markdown/EditorProvenance Documents/ReadingDocument; do
        cat "$project_directory/Sources/Remile/$file.swift"
    done
    sed '/^struct PDFProtectionButton/,$d' "$project_directory/Sources/Remile/PDF/PDFEditProtection.swift"
    cat "$project_directory/Sources/Remile/PDF/PDFFileAccess.swift"
    sed '/^struct ReadingShell/,$d' "$project_directory/Sources/Remile/Documents/ReadingSession.swift"
    cat "$project_directory/Tests/PDFSignatureChecks/session.swift"
} > "$check_directory/signature-save-checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/signature-save-checks.swift" "$check_directory"
result="$(pdfsig -nocert -no-ocsp "$check_directory/session-save.pdf" 2>&1)"
print -r -- "$result"
[[ "$result" == *'Signature Validation: Signature is Valid.'* ]] || exit 1
