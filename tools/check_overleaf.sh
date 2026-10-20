#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide a new external output directory}"
python_path="${2:?Provide the current host agent Python}"
mkdir -p "$check_directory/module-cache"
{
    cat "$project_directory/Sources/Remile/App/KeychainAccess.swift"
    cat "$project_directory/Sources/Remile/LaTeX/TeXFileSystem.swift"
    cat "$project_directory/Sources/Remile/Overleaf/OverleafGit.swift"
    cat "$project_directory/Tests/OverleafChecks/main.swift"
} > "$check_directory/checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/checks.swift" "$check_directory" "$python_path"
