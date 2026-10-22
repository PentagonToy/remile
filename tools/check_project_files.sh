#!/bin/zsh
set -eu
project_directory="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="${1:?Provide an external output directory}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
source_paths=("$project_directory"/Sources/Remile/**/*.swift(.N))
source_paths=("${(@)source_paths:#*/App/RemileApp.swift}")
{
    for source_path in "${source_paths[@]}"; do
        print -r -- "#sourceLocation(file: \"$source_path\", line: 1)"
        cat "$source_path"
        print
    done
    print -r -- '#sourceLocation()'
    cat "$project_directory/Tests/ProjectFileChecks/main.swift"
} > "$check_directory/project-file-checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/project-file-checks.swift" "$check_directory" "${@[2,-1]}"
