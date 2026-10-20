#!/bin/zsh
set -eu
project_directory="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="${1:?Provide an absolute output directory under Agents/Repository}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
cat "$project_directory/Sources/Remile/Search/SearchMarkdown.swift" \
    "$project_directory/Sources/Remile/Search/SearchText.swift" \
    "$project_directory/Sources/Remile/Assistant/AppleIntelligence.swift" \
    "$project_directory/Sources/Remile/Assistant/AssistantEngine.swift" \
    "$project_directory/Sources/Remile/Search/SearchExpansion.swift" \
    "$project_directory/Sources/Remile/Search/LibraryIndex.swift" \
    "$project_directory/Sources/Remile/Assistant/AssistantPassage.swift" \
    "$project_directory/Sources/Remile/Assistant/Prompts/AssistantPrompts.swift" \
    "$project_directory/Sources/Remile/Assistant/Prompts/AssistantAnswerPrompts.swift" \
    "$project_directory/Sources/Remile/Assistant/DocumentAssistant.swift" \
    "$project_directory/Sources/Remile/Search/SearchAssistantContext.swift" > "$check_directory/search-assistant-checks.swift"
cat >> "$check_directory/search-assistant-checks.swift" <<'SWIFT'
@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}
SWIFT
cat "$project_directory/Tests/SearchAssistantChecks/main.swift" >> "$check_directory/search-assistant-checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/search-assistant-checks.swift" "$check_directory" "${2:-}"
