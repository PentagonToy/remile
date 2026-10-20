#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an external output directory}"
mkdir -p "$check_directory/module-cache"
{
    cat "$project_directory/Sources/Remile/App/KeychainAccess.swift"
    for name in ChatGPTIdentity ChatGPTCallback ChatGPTEdit ChatGPTStream ChatGPTRequestFailure; do cat "$project_directory/Sources/Remile/Assistant/$name.swift"; done
    sed '/^extension TeXProject/,$d' "$project_directory/Sources/Remile/LaTeX/TeXCollections.swift"
    cat "$project_directory/Sources/Remile/LaTeX/TeXFileSystem.swift"
    cat "$project_directory/Sources/Remile/Overleaf/OverleafGit.swift"
    cat "$project_directory/Sources/Remile/Overleaf/OverleafWebIdentity.swift"
    echo 'struct OverleafThreadArchive { static func parse(_ data: Data, project: OverleafConnection) throws -> Self { Self() } }'
    cat "$project_directory/Sources/Remile/App/AppRelease.swift" \
    "$project_directory/Sources/Remile/Overleaf/OverleafWebClient.swift"
    cat "$project_directory/Tests/NativeConnectionChecks/main.swift"
} > "$check_directory/checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/checks.swift"
