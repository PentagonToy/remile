#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an external output directory}"
mkdir -p "$check_directory/module-cache"
{
    cat "$project_directory/Sources/Remile/Assistant/Prompts/AssistantPrompts.swift"
    cat "$project_directory/Sources/Remile/Assistant/AppleIntelligence.swift"
    cat "$project_directory/Sources/Remile/Markdown/EditorSpellcheck.swift"
    cat "$project_directory/Sources/Remile/Markdown/EditorSynonyms.swift"
    cat "$project_directory/Tests/SynonymChecks/main.swift"
} > "$check_directory/checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/checks.swift"
