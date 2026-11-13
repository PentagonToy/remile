#!/bin/zsh
set -euo pipefail
project_directory="${0:A:h:h}"
check_directory="${1:?Use an absolute external check directory}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory"
{
    for source_path in "$project_directory"/Sources/Remile/**/*.swift; do
        [[ "${source_path:t}" == RemileApp.swift ]] && continue
        printf '#sourceLocation(file: "%s", line: 1)\n' "$source_path"
        cat "$source_path"
        printf '\n#sourceLocation()\n'
    done
    cat "$project_directory/Tests/WriterChecks/Fixtures.swift"
    cat "$project_directory/Tests/WriterChecks/main.swift"
} > "$check_directory/checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/checks.swift" "$check_directory"
