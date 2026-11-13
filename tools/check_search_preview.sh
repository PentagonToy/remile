#!/bin/zsh
set -eu
project_directory="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="${1:?Provide an absolute output directory under Agents/Repository}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
paths=("$project_directory"/Sources/Remile/**/*.swift(.N))
paths=("${(@)paths:#*/App/RemileApp.swift}")
for source_path in "${paths[@]}"; do
    cat "$source_path"
    print
done > "$check_directory/search-preview-checks.swift"
cat >> "$check_directory/search-preview-checks.swift" <<'SWIFT'
// Interpreter-only SDK availability symbol; use the actual host version.
@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}

SWIFT
cat "$project_directory/Tests/SearchPreviewChecks/main.swift" >> "$check_directory/search-preview-checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/search-preview-checks.swift" "$check_directory"
