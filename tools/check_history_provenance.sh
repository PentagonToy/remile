#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an external output directory}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory"
cat "$project_directory/Sources/Remile/LaTeX/TeXHistory.swift" "$project_directory/Sources/Remile/Markdown/EditorProvenance.swift" "$project_directory/Tests/HistoryProvenanceChecks/main.swift" > "$check_directory/history-checks.swift"
swift "$check_directory/history-checks.swift" "$check_directory"
