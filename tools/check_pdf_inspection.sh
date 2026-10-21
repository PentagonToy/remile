#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide a new external output directory}"
mkdir -p "$check_directory/module-cache"
cat "$project_directory/Sources/Remile/Automation/PDFInspection.swift" "$project_directory/Tests/PDFInspectionChecks/main.swift" > "$check_directory/checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/checks.swift" "$check_directory"
