#!/bin/zsh
set -eu
project_directory="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="${1:?Provide an absolute external output directory}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
cat "$project_directory/Sources/Remile/PDF/HighlightPalette.swift" \
    "$project_directory/Sources/Remile/PDF/PDFDrawing.swift" \
    "$project_directory/Sources/Remile/PDF/PDFSelectionActions.swift" \
    "$project_directory/Tests/PDFSelectionChecks/main.swift" > "$check_directory/pdf-selection-checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/pdf-selection-checks.swift" "$check_directory"
