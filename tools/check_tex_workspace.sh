#!/bin/zsh
set -eu
project_directory="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="${1:?Provide an external output directory}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
{
    for source_path in "$project_directory/Sources/Remile/App/AnimationPolicy.swift" "$project_directory/Sources/Remile/App/RemileStyle.swift" "$project_directory"/Sources/Remile/LaTeX/{TeXSyntax,TeXDiagnostics,TeXSync,TeXMainDocument}.swift; do
        print -r -- "#sourceLocation(file: \"$source_path\", line: 1)"
        cat "$source_path"
        print
    done
    print -r -- '#sourceLocation()'
    cat "$project_directory/Tests/TeXWorkspaceChecks/main.swift"
} > "$check_directory/tex-workspace-checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/tex-workspace-checks.swift" "${@[2,-1]}"
