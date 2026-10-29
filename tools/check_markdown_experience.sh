#!/bin/zsh
set -eu
project_directory="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="${1:?Provide an absolute output directory under Agents/Repository}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
# The editor shares completion, spelling and navigation code with the other workspaces.
: > "$check_directory/markdown-experience.swift"
for source_path in "$project_directory"/Sources/Remile/**/*.swift; do
    [[ "${source_path:t}" == RemileApp.swift ]] && continue
    cat "$source_path" >> "$check_directory/markdown-experience.swift"
    printf '\n' >> "$check_directory/markdown-experience.swift"
done
cat "$project_directory/Tests/MarkdownExperienceChecks/main.swift" >> "$check_directory/markdown-experience.swift"

swift -module-cache-path "$check_directory/module-cache" "$check_directory/markdown-experience.swift" "$check_directory"
