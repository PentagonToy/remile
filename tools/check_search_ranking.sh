#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an external output directory}"
mkdir -p "$check_directory/module-cache"
cat "$project_directory/Sources/Remile/Search/SearchLexicon.swift" \
    "$project_directory/Sources/Remile/Search/SparseSearchRanker.swift" \
    "$project_directory/Sources/Remile/Assistant/AppleIntelligence.swift" \
    "$project_directory/Sources/Remile/Assistant/AIConfiguration.swift" \
    "$project_directory/Sources/Remile/App/NetworkAccess.swift" \
    "$project_directory/Sources/Remile/Search/SearchBoost.swift" \
    "$project_directory/Tests/SearchRankingChecks/main.swift" > "$check_directory/checks.swift"
swiftc -O -module-cache-path "$check_directory/module-cache" "$check_directory/checks.swift" -o "$check_directory/search-ranking-checks"
"$check_directory/search-ranking-checks" "${2:-}"
