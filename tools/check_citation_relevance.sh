#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
output="${1:?Provide an external absolute output directory}"
case "$output" in /*) ;; *) exit 1 ;; esac
[[ "$output" != "$project_directory" && "$output" != "$project_directory"/* ]] || exit 1
mkdir -p "$output/module-cache"
paths=("$project_directory"/Sources/Remile/**/*.swift(.N))
paths=("${(@)paths:#*/App/RemileApp.swift}")
for source_path in "${paths[@]}" "$project_directory/Tests/CitationRelevanceChecks/main.swift"; do
    cat "$source_path"
    print
done > "$output/checks.swift"
swift -module-cache-path "$output/module-cache" "$output/checks.swift" "$output"
