#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
output="${1:?Provide an external absolute output directory}"
case "$output" in /*) ;; *) exit 1 ;; esac
mkdir -p "$output/module-cache"
source_paths=("$project_directory"/Sources/Remile/**/*.swift(.N))
source_paths=("${(@)source_paths:#*/App/RemileApp.swift}")
cat "${source_paths[@]}" "$project_directory/Tests/ReferenceRecognitionChecks/main.swift" > "$output/checks.swift"
swift -module-cache-path "$output/module-cache" "$output/checks.swift" "$output" "${@[2,-1]}"
