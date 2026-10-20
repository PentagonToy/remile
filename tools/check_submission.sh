#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide a new external output directory}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory"
cat "$project_directory/Sources/Remile/LaTeX/TeXFileSystem.swift" "$project_directory/Sources/Remile/LaTeX/TeXSourceSnapshot.swift" "$project_directory/Sources/Remile/LaTeX/TeXCompiler.swift" "$project_directory/Sources/Remile/LaTeX/TeXSourceTools.swift" "$project_directory/Sources/Remile/LaTeX/TeXSubmissionComparison.swift" "$project_directory/Tests/SubmissionChecks/main.swift" > "$check_directory/submission-checks.swift"
swift "$check_directory/submission-checks.swift" "$check_directory"
