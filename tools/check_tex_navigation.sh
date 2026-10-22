#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an absolute external output directory}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
{
    for source_path in "$project_directory"/Sources/Remile/**/*.swift(.N); do
        [[ "$source_path" == */App/RemileApp.swift ]] || cat "$source_path"
    done
    cat "$project_directory/Tests/TeXNavigationChecks/main.swift"
} > "$check_directory/checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/checks.swift"
