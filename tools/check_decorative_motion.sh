#!/bin/zsh
set -euo pipefail
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an absolute external check directory}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
cat "$project_directory/Sources/Remile/App/AnimationPolicy.swift" "$project_directory/Sources/Remile/App/DecorativePhaseTime.swift" "$project_directory/Sources/Remile/App/DecorativeTimeline.swift" "$project_directory/Tests/DecorativeMotionChecks/main.swift" > "$check_directory/checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/checks.swift"
