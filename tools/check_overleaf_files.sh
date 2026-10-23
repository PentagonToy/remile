#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an external output directory}"
mkdir -p "$check_directory/module-cache"
source_paths=("$project_directory"/Sources/Remile/**/*.swift(.N))
source_paths=("${(@)source_paths:#*/App/RemileApp.swift}")
for source_path in "${source_paths[@]}" "$project_directory/Tests/OverleafFileChecks/main.swift"; do
    printf '#sourceLocation(file: "%s", line: 1)\n' "$source_path"
    cat "$source_path"
    printf '\n#sourceLocation()\n'
done > "$check_directory/checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/checks.swift" "$check_directory"
