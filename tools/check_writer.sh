#!/bin/zsh
set -euo pipefail
project_directory="${0:A:h:h}"
check_directory="${1:?Use an absolute external check directory}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory"
{
    cat "$project_directory/Tests/WriterChecks/Fixtures.swift"
    sed -n '1,/    static var directory:/p' "$project_directory/Sources/Remile/Automation/EditorBridge.swift" | sed '$d'
    print '}'
    for source_path in "$project_directory"/Sources/Remile/{App/{AnimationPolicy,RemileStyle,RemileControls,RemileHelp,ReaderSplit,WorkspaceLayout,EditorSidebarBrand,ReaderThemeButton,RemileOptionPicker,StorageFileAccess}.swift,Documents/SourceDigest.swift,PDF/PaperSize.swift,Markdown/MathMarkup.swift,Convert/{WordArchive,WordArt,WordXML,WordImages,WordShape,WordMath}.swift,Reference/{ReferenceRecord,ReferenceText,ReferenceLibrary,ReferenceMergePlan,ReferenceSavePanel}.swift,Writer/*.swift,Search/SearchPreviewSplit.swift}; do
        printf '#sourceLocation(file: "%s", line: 1)\n' "$source_path"
        cat "$source_path"
        printf '\n#sourceLocation()\n'
    done
    cat "$project_directory/Tests/WriterChecks/main.swift"
} > "$check_directory/checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/checks.swift" "$check_directory"
