#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an external output directory}"
mkdir -p "$check_directory/module-cache"
{
    cat "$project_directory/Sources/Remile/App/NetworkAccess.swift" \
    "$project_directory/Sources/Remile/Assistant/AIConfiguration.swift" \
    "$project_directory/Sources/Remile/App/KeychainAccess.swift"
    cat "$project_directory/Sources/Remile/LaTeX/TeXFileSystem.swift"
    cat "$project_directory/Sources/Remile/Overleaf/OverleafGit.swift"
    for file in PDFReplyWriter PDFFormPreservation PDFCommentGraph PDFCommentExport; do cat "$project_directory/Sources/Remile/PDF/$file.swift"; done
    cat "$project_directory/Sources/Remile/Overleaf/OverleafThreadArchive.swift"
    cat "$project_directory/Tests/OverleafCommentChecks/main.swift"
} > "$check_directory/checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/checks.swift"
