#!/bin/zsh
set -eu
project_directory="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="${1:?Provide an absolute external output directory}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
: > "$check_directory/interface-checks.swift"
while IFS= read -r source; do
    [[ "$source" == */DeerstalkerApp.swift ]] && continue
    cat "$source" >> "$check_directory/interface-checks.swift"
    print >> "$check_directory/interface-checks.swift"
done < <(rg --files "$project_directory/Sources" -g '*.swift' | sort)
cat "$project_directory/Tests/InterfaceChecks/main.swift" >> "$check_directory/interface-checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/interface-checks.swift" "$check_directory"
