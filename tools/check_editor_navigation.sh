#!/bin/zsh
set -eu
root="${0:A:h:h}"
output="${1:?Provide an external output directory}"
case "$output" in /*) ;; *) exit 1 ;; esac
[[ "$output" != "$root" && "$output" != "$root"/* ]] || exit 1
mkdir -p "$output/module-cache"
source_paths=("$root"/Sources/Remile/**/*.swift(.N))
source_paths=("${(@)source_paths:#*/App/RemileApp.swift}")
{
    for source_path in "${source_paths[@]}"; do
        print -r -- "#sourceLocation(file: \"$source_path\", line: 1)"
        cat "$source_path"
        print
    done
    print -r -- '#sourceLocation()'
    cat "$root/Tests/EditorNavigationChecks/main.swift"
} > "$output/checks.swift"
swift -module-cache-path "$output/module-cache" "$output/checks.swift" "$output"
