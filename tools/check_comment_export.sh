#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an external output directory}"
mkdir -p "$check_directory/module-cache"
{
    for file in PDFReplyWriter PDFFormPreservation PDFSignedAnnotations PDFCommentGraph PDFCommentExport; do cat "$project_directory/Sources/Remile/PDF/$file.swift"; done
    cat "$project_directory/Tests/CommentExportChecks/main.swift"
} > "$check_directory/checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/checks.swift" "$check_directory"
