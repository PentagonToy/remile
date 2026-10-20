#!/bin/zsh
set -eu
project_directory="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="${1:?Provide an absolute output directory under Agents/Repository}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
cat "$project_directory/Sources/Remile/App/RemileStyle.swift" \
    "$project_directory/Sources/Remile/Markdown/MarkdownEditing.swift" \
    "$project_directory/Sources/Remile/Markdown/MathCompletion.swift" \
    "$project_directory/Sources/Remile/Markdown/MarkdownEditor.swift" \
    "$project_directory/Tests/MathCompletionChecks/main.swift" > "$check_directory/math-completion.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/math-completion.swift"
