#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an external output directory}"
mkdir -p "$check_directory/module-cache"
{
    cat "$project_directory/Sources/Remile/Overleaf/OverleafProjectID.swift"
    cat "$project_directory/Sources/Remile/Documents/SourceDigest.swift"
    cat "$project_directory/Sources/Remile/LaTeX/TeXFileSystem.swift"
    cat "$project_directory/Sources/Remile/Automation/OverleafCommands.swift"
    cat "$project_directory/Tests/OverleafCommandChecks/main.swift"
} > "$check_directory/checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/checks.swift" "$check_directory"
