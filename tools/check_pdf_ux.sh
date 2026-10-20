#!/bin/zsh
set -eu
project_directory="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="${1:?Provide an absolute external output directory}"
paper_path="${2:?Provide the read-only paper PDF path}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
source_paths=("$project_directory"/Sources/Remile/**/*.swift(.N))
source_paths=("${(@)source_paths:#*/App/RemileApp.swift}")
/usr/bin/shasum -a 256 "${source_paths[@]}" "$project_directory/Tests/PDFUXChecks/main.swift" > "$check_directory/source-sha256.txt"
cat "${source_paths[@]}" "$project_directory/Tests/PDFUXChecks/main.swift" > "$check_directory/pdf-ux-checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/pdf-ux-checks.swift" "$check_directory" "$paper_path"
