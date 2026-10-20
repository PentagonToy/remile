#!/bin/zsh
set -eu
project_directory="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="${1:?Provide an external output directory}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
source_paths=("$project_directory"/Sources/Remile/**/*.swift(.N))
source_paths=("${(@)source_paths:#*/App/RemileApp.swift}")
cat "${source_paths[@]}" "$project_directory/Tests/PageAssemblyChecks/main.swift" > "$check_directory/page-assembly-checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/page-assembly-checks.swift" "$check_directory" "${@[2,-1]}"
