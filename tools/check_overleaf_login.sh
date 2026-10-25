#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
output="${1:?Provide an external absolute output directory}"
case "$output" in /*) ;; *) exit 1 ;; esac
mkdir -p "$output/module-cache"
cat "$project_directory/Sources/Remile/Overleaf/OverleafLoginForm.swift" "$project_directory/Tests/OverleafLoginFormChecks/main.swift" > "$output/checks.swift"
swift -module-cache-path "$output/module-cache" "$output/checks.swift"
