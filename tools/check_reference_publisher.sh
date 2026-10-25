#!/bin/zsh
set -eu
root="${0:A:h:h}"
output="${1:?Provide an external output directory}"
case "$output" in /*) ;; *) exit 1 ;; esac
[[ "$output" != "$root" && "$output" != "$root"/* ]] || exit 1
mkdir -p "$output/module-cache"
paths=("$root"/Sources/Remile/**/*.swift(.N))
paths=("${(@)paths:#*/App/RemileApp.swift}")
for source_path in "${paths[@]}" "$root/Tests/ReferencePublisherChecks/main.swift"; do
    printf '#sourceLocation(file: "%s", line: 1)\n' "$source_path"
    cat "$source_path"
    printf '\n#sourceLocation()\n'
done > "$output/checks.swift"
swift -module-cache-path "$output/module-cache" "$output/checks.swift" "${@[2,-1]}"
