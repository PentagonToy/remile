#!/bin/zsh
set -eu
project_directory="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="${1:?Provide an absolute output directory under Agents/Repository}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
source_paths=("$project_directory"/Sources/Remile/**/*.swift(.N))
source_paths=("${(@)source_paths:#*/App/RemileApp.swift}")
cat "${source_paths[@]}" "$project_directory/Tests/MathCompletionChecks/main.swift" > "$check_directory/math-completion.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/math-completion.swift"
