#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide a new external output directory}"
mkdir -p "$check_directory/module-cache"
{
    cat "$project_directory/Sources/Remile/App/NetworkAccess.swift"
    for source_path in "$project_directory"/Sources/Remile/Overleaf/Realtime/*.swift; do
        [[ "$source_path" == */OverleafLiveWorkspace.swift ]] || cat "$source_path"
    done
    cat "$project_directory/Tests/OverleafRealtimeChecks/main.swift"
} > "$check_directory/checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/checks.swift" "$check_directory"
