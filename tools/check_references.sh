#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an external output directory}"
mkdir -p "$check_directory/module-cache"
check_main="${REMILE_REFERENCE_CHECK_MAIN:-$project_directory/Tests/ReferenceChecks/main.swift}"
source_paths=("$project_directory"/Sources/Remile/**/*.swift(.N))
source_paths=("${(@)source_paths:#*/App/RemileApp.swift}")
for source_path in "${source_paths[@]}" "$check_main"; do
    printf '#sourceLocation(file: "%s", line: 1)\n' "$source_path"
    cat "$source_path"
    printf '\n#sourceLocation()\n'
done > "$check_directory/checks.swift"
if ! rg -q '_cdecl\("__isPlatformVersionAtLeast"\)' "$check_main"; then
    cat >> "$check_directory/checks.swift" <<'SWIFT'
@_cdecl("__isPlatformVersionAtLeast")
public func referenceHostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}
SWIFT
fi
swift -module-cache-path "$check_directory/module-cache" "$check_directory/checks.swift" "$check_directory" "${@[2,-1]}"
