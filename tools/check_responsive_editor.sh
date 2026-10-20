#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an external output directory}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
{
    for file in LaTeX/TeXSourceTools.swift Markdown/MarkdownEditing.swift Markdown/EditorSourceEditing.swift Markdown/MathCompletion.swift Markdown/EditorCompletion.swift; do cat "$project_directory/Sources/Remile/$file"; done
    cat "$project_directory/Tests/ResponsiveEditorChecks/main.swift"
} > "$check_directory/checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/checks.swift"
