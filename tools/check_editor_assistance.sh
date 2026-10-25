#!/bin/zsh
set -eu
root="${0:A:h:h}"
output="${1:?Provide an external output directory}"
case "$output" in /*) ;; *) exit 1 ;; esac
[[ "$output" != "$root" && "$output" != "$root"/* ]] || exit 1
mkdir -p "$output/module-cache"
{
    cat "$root/Sources/Remile/Markdown/MarkdownEditing.swift" "$root/Sources/Remile/Markdown/MathCompletion.swift"
    sed '/@MainActor final class EditorCompletionPanel/,$d' "$root/Sources/Remile/Markdown/EditorCompletion.swift"
    cat "$root/Sources/Remile/LaTeX/TeXLocalCompletion.swift" "$root/Tests/EditorAssistanceChecks/main.swift"
} > "$output/checks.swift"
swift -module-cache-path "$output/module-cache" "$output/checks.swift"
