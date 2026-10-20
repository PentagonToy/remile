#!/bin/zsh
set -eu
project_directory="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="${1:?Provide an absolute output directory under Agents/Repository}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
cat "$project_directory/Sources/Deerstalker/Search/LibraryIndex.swift" \
    "$project_directory/Sources/Deerstalker/Home/DocumentTools.swift" \
    "$project_directory/Tests/DocumentToolChecks/main.swift" > "$check_directory/tool-checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/tool-checks.swift" "$check_directory/tool-fixtures" "$check_directory/threaded.pdf"
