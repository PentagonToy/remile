#!/bin/zsh
set -eu
root="${0:A:h:h}"
output="${1:?Provide an external output directory}"
case "$output" in /*) ;; *) exit 1 ;; esac
[[ "$output" != "$root" && "$output" != "$root"/* ]] || exit 1
mkdir -p "$output/module-cache"
cat "$root/Sources/Remile/App/AnimationPolicy.swift" \
    "$root/Sources/Remile/App/RemileStyle.swift" \
    "$root/Sources/Remile/App/RemileControls.swift" \
    "$root/Sources/Remile/App/RemileHelp.swift" \
    "$root/Sources/Remile/App/WorkspaceLayout.swift" \
    "$root/Sources/Remile/App/ReaderSplit.swift" \
    "$root/Sources/Remile/PDF/PDFThumbnailCache.swift" \
    "$root/Sources/Remile/PDF/PDFSidebarPresentation.swift" \
    "$root/Sources/Remile/PDF/PDFNavigationPanel.swift" \
    "$root/Sources/Remile/Home/WelcomeTour.swift" \
    "$root/Tests/ReaderPerformanceChecks/main.swift" > "$output/checks.swift"
swift -module-cache-path "$output/module-cache" "$output/checks.swift" "$output"
