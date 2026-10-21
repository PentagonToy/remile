#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an external output directory}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
{
    for file in TeXFileSystem TeXSourceSnapshot TeXCompiler TeXEnvironment TeXDiagnostics TeXBuildReport TeXPackageResolver TeXDiagnosticAdvice; do cat "$project_directory/Sources/Remile/LaTeX/$file.swift"; done
    cat "$project_directory/Sources/Remile/App/NetworkAccess.swift"
    cat "$project_directory/Tests/TeXGuidanceChecks/main.swift"
} > "$check_directory/tex-guidance.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/tex-guidance.swift" "$check_directory"
