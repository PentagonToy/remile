#!/bin/zsh
set -eu
root="${0:A:h:h}"
output="${1:?Provide an external output directory}"
case "$output" in /*) ;; *) exit 1 ;; esac
[[ "$output" != "$root" && "$output" != "$root"/* ]] || exit 1
mkdir -p "$output/module-cache"
# Use the actual registry and zoom controller with lightweight document doubles.
{
    print -r -- '@MainActor'
    sed -n '/^@MainActor$/,$p' "$root/Sources/Remile/Documents/ReadingSession.swift" | sed -n '/^final class RemileWindows/,$p'
    sed '/^struct ReaderZoomControls/,$d' "$root/Sources/Remile/App/ReaderZoom.swift"
    cat "$root/Sources/Remile/App/AnimationPolicy.swift"
    cat "$root/Sources/Remile/PDF/PDFTabDragSurface.swift"
    cat "$root/Sources/Remile/App/RemileStyle.swift"
    cat "$root/Sources/Remile/App/RemileControls.swift"
    cat "$root/Sources/Remile/App/RemileHelp.swift"
    cat "$root/Sources/Remile/App/ReaderThemeButton.swift"
    cat "$root/Sources/Remile/PDF/PDFDocumentTabs.swift"
    cat "$root/Tests/PDFTabChecks/main.swift"
} > "$output/checks.swift"
swift -module-cache-path "$output/module-cache" "$output/checks.swift" "$output"
