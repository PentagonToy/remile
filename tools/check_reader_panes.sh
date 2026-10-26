#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an external output directory}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
cat "$project_directory/Sources/Remile/App/WorkspaceLayout.swift" "$project_directory/Sources/Remile/App/ReaderSplit.swift" "$project_directory/Tests/ReaderPaneChecks/main.swift" > "$check_directory/pane-checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/pane-checks.swift"
