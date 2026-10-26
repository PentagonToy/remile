#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide a new external output directory}"
mkdir -p "$check_directory/module-cache"
{
    cat "$project_directory/Sources/Remile/App/NetworkAccess.swift"
    for file in OverleafLiveState OverleafLiveText OverleafLiveJournal OverleafLiveCoordinator OverleafLiveWire; do
        cat "$project_directory/Sources/Remile/Overleaf/Realtime/$file.swift"
    done
    cat "$project_directory/Tests/OverleafRealtimeChecks/main.swift"
} > "$check_directory/checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/checks.swift" "$check_directory"
