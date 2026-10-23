#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an external output directory}"
mkdir -p "$check_directory/module-cache"
"${REMILE_CHECK_PYTHON:-python3}" "$project_directory/Tests/OverleafFreeChecks/fixtures.py" "${check_directory:h}/fixtures"
source_paths=("$project_directory"/Sources/Remile/**/*.swift(.N))
source_paths=("${(@)source_paths:#*/App/RemileApp.swift}")
for source_path in "${source_paths[@]}" "$project_directory/Tests/OverleafConnectionChecks/LiveWorkspace.swift" "$project_directory/Tests/OverleafFreeChecks/main.swift"; do
    printf '#sourceLocation(file: "%s", line: 1)\n' "$source_path"
    cat "$source_path"
    printf '\n#sourceLocation()\n'
done > "$check_directory/checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/checks.swift" "$check_directory"
