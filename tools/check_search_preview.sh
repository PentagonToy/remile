#!/bin/zsh
set -eu
project_directory="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="${1:?Provide an absolute output directory under Agents/Repository}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
cat "$project_directory/Sources/Remile/App/StorageLocation.swift" \
    "$project_directory/Sources/Remile/Assistant/AssistantPassage.swift" \
    "$project_directory/Sources/Remile/PDF/PDFCitation.swift" \
    "$project_directory/Sources/Remile/App/AnimationPolicy.swift" \
    "$project_directory/Sources/Remile/App/RemileStyle.swift" \
    "$project_directory/Sources/Remile/App/RemileHelp.swift" \
    "$project_directory/Sources/Remile/App/ReaderZoom.swift" \
    "$project_directory/Sources/Remile/Search/SearchMarkdown.swift" \
    "$project_directory/Sources/Remile/Search/SearchText.swift" \
    "$project_directory/Sources/Remile/Assistant/AppleIntelligence.swift" \
    "$project_directory/Sources/Remile/Assistant/AssistantEngine.swift" \
    "$project_directory/Sources/Remile/Assistant/Prompts/AssistantPrompts.swift" \
    "$project_directory/Sources/Remile/Search/SearchExpansion.swift" \
    "$project_directory/Sources/Remile/Search/SearchLexicon.swift" \
    "$project_directory/Sources/Remile/Search/SparseSearchRanker.swift" \
    "$project_directory/Sources/Remile/Search/LibraryIndex.swift" \
    "$project_directory/Sources/Remile/Search/SearchResultGroup.swift" \
    "$project_directory/Sources/Remile/Search/SearchCover.swift" \
    "$project_directory/Sources/Remile/PDF/HighlightPalette.swift" \
    "$project_directory/Sources/Remile/PDF/PDFReplyWriter.swift" \
    "$project_directory/Sources/Remile/PDF/PDFFormPreservation.swift" \
    "$project_directory/Sources/Remile/PDF/PDFSignedAnnotations.swift" \
    "$project_directory/Sources/Remile/PDF/PDFCommentGraph.swift" \
    "$project_directory/Sources/Remile/PDF/PDFNotes.swift" \
    "$project_directory/Sources/Remile/PDF/PDFEditing.swift" \
    "$project_directory/Sources/Remile/PDF/PDFHighlightStore.swift" \
    "$project_directory/Sources/Remile/PDF/PDFEditProtection.swift" \
    "$project_directory/Sources/Remile/PDF/PDFDrawing.swift" \
    "$project_directory/Sources/Remile/PDF/PageNavigationPDFView.swift" \
    "$project_directory/Sources/Remile/PDF/PDFSelectionActions.swift" \
    "$project_directory/Sources/Remile/PDF/PDFSelectionPassages.swift" \
    "$project_directory/Sources/Remile/PDF/SelectionTranslation.swift" \
    "$project_directory/Sources/Remile/Search/SearchPDFHighlights.swift" \
    "$project_directory/Sources/Remile/Search/SearchPDFPreview.swift" > "$check_directory/search-preview-checks.swift"
cat >> "$check_directory/search-preview-checks.swift" <<'SWIFT'
// Interpreter-only SDK availability symbol; use the actual host version.
@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}
// The preview tests do not open a reader document window.
@MainActor final class ReaderNavigation {
    static let shared = ReaderNavigation()
    func reveal(_ hit: LibraryHit, query: String, noteExcerpt: String? = nil) { }
}
SWIFT
cat "$project_directory/Tests/SearchPreviewChecks/main.swift" >> "$check_directory/search-preview-checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/search-preview-checks.swift" "$check_directory"
