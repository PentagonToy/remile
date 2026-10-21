#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
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
    "$project_directory/Sources/Remile/Markdown/MarkdownRemoteImages.swift" \
    "$project_directory/Sources/Remile/Markdown/MarkdownImagePresentation.swift" \
    "$project_directory/Sources/Remile/Markdown/MarkdownPreview.swift" \
    "$project_directory/Tests/MarkdownImageChecks/main.swift" > "$check_directory/markdown-images.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/markdown-images.swift" "$check_directory" "$project_directory"
