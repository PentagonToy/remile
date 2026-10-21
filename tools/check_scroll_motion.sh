#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an external output directory}"
mkdir -p "$check_directory/module-cache"
cat "$project_directory/Sources/Remile/App/AnimationPolicy.swift" "$project_directory/Sources/Remile/App/ReaderScrolling.swift" "$project_directory/Sources/Remile/App/ScrollMotion.swift" "$project_directory/Tests/ScrollMotionChecks/main.swift" > "$check_directory/checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/checks.swift"
