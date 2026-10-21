#!/bin/zsh
set -eu
project_directory="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="${1:?Provide an absolute output directory under Agents/Repository}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
cat "$project_directory/Sources/Remile/App/NetworkAccess.swift" \
    "$project_directory/Sources/Remile/Assistant/AIConfiguration.swift" \
    "$project_directory/Sources/Remile/Markdown/MathMarkup.swift" \
    "$project_directory/Sources/Remile/App/ReaderScrolling.swift" "$project_directory/Sources/Remile/App/ScrollMotion.swift" \
    "$project_directory/Sources/Remile/App/AnimationPolicy.swift" "$project_directory/Sources/Remile/App/RemileStyle.swift" \
    "$project_directory/Sources/Remile/Markdown/MarkdownHTML.swift" \
    "$project_directory/Sources/Remile/Markdown/MarkdownPDF.swift" \
    "$project_directory/Sources/Remile/Search/SearchMarkdown.swift" \
    "$project_directory/Sources/Remile/Assistant/ReadableMath.swift" \
    "$project_directory/Sources/Remile/Markdown/MarkdownEditing.swift" \
    "$project_directory/Sources/Remile/Markdown/MathCompletion.swift" \
    "$project_directory/Sources/Remile/Markdown/MarkdownEditor.swift" \
    "$project_directory/Sources/Remile/Markdown/MarkdownPreview.swift" \
    "$project_directory/Tests/MarkdownExperienceChecks/main.swift" > "$check_directory/markdown-experience.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/markdown-experience.swift" "$check_directory"
