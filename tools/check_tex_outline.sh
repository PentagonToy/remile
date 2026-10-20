#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an external output directory}"
mkdir -p "$check_directory/module-cache"
{
    print 'import Foundation'
    sed -n '/^struct TeXOutlineItem/,$p' "$project_directory/Sources/Remile/LaTeX/TeXHistory.swift"
    cat "$project_directory/Tests/TeXOutlineChecks/main.swift"
} > "$check_directory/checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/checks.swift"
