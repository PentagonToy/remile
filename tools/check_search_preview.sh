#!/bin/zsh
set -eu
project_directory="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="${1:?Provide an absolute output directory under Agents/Repository}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
cat "$project_directory/Sources/Deerstalker/Assistant/AssistantPassage.swift" \
    "$project_directory/Sources/Deerstalker/PDF/PDFCitation.swift" \
    "$project_directory/Sources/Deerstalker/App/DeerStyle.swift" \
    "$project_directory/Sources/Deerstalker/App/ReaderZoom.swift" \
    "$project_directory/Sources/Deerstalker/Search/SearchMarkdown.swift" \
    "$project_directory/Sources/Deerstalker/Search/SearchText.swift" \
    "$project_directory/Sources/Deerstalker/Assistant/AppleIntelligence.swift" \
    "$project_directory/Sources/Deerstalker/Search/SearchExpansion.swift" \
    "$project_directory/Sources/Deerstalker/Search/LibraryIndex.swift" \
    "$project_directory/Sources/Deerstalker/Search/SearchResultGroup.swift" \
    "$project_directory/Sources/Deerstalker/Search/SearchCover.swift" \
    "$project_directory/Sources/Deerstalker/PDF/HighlightPalette.swift" \
    "$project_directory/Sources/Deerstalker/PDF/PDFReplyWriter.swift" \
    "$project_directory/Sources/Deerstalker/PDF/PDFCommentGraph.swift" \
    "$project_directory/Sources/Deerstalker/PDF/PDFHighlightStore.swift" \
    "$project_directory/Sources/Deerstalker/Search/SearchPDFHighlights.swift" \
    "$project_directory/Sources/Deerstalker/Search/SearchPDFPreview.swift" > "$check_directory/search-preview-checks.swift"
cat >> "$check_directory/search-preview-checks.swift" <<'SWIFT'
// Interpreter-only SDK availability symbol; use the actual host version.
@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}
// The preview tests do not open a reader document window.
@MainActor final class ReaderNavigation {
    static let shared = ReaderNavigation()
    func reveal(_ hit: LibraryHit, query: String) { }
}
SWIFT
cat "$project_directory/Tests/SearchPreviewChecks/main.swift" >> "$check_directory/search-preview-checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/search-preview-checks.swift" "$check_directory"
