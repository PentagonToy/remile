#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an external output directory}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
cat "$project_directory/Sources/Remile/App/AnimationPolicy.swift" \
    "$project_directory/Sources/Remile/App/RemileStyle.swift" \
    "$project_directory/Sources/Remile/App/RemileControls.swift" \
    "$project_directory/Sources/Remile/App/RemileHelp.swift" \
    "$project_directory/Tests/DesignSystemChecks/main.swift" > "$check_directory/design-checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/design-checks.swift" "$check_directory"
