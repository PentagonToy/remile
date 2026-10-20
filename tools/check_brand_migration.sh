#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an external output directory}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory"
cat "$project_directory/Sources/Remile/App/LegacyMigration.swift" "$project_directory/Tests/BrandMigrationChecks/main.swift" > "$check_directory/migration-checks.swift"
swift "$check_directory/migration-checks.swift" "$check_directory/fixture"
