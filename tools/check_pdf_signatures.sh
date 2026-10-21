#!/bin/zsh
set -eu
project_directory="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="${1:?Provide an absolute external output directory}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
mkdir -p "$check_directory/module-cache"
cat "$project_directory/Sources/Remile/PDF/HighlightPalette.swift" \
    "$project_directory/Sources/Remile/PDF/PDFReplyWriter.swift" \
    "$project_directory/Sources/Remile/PDF/PDFFormPreservation.swift" \
    "$project_directory/Sources/Remile/PDF/PDFSignedAnnotations.swift" \
    "$project_directory/Sources/Remile/PDF/PDFCommentGraph.swift" \
    "$project_directory/Sources/Remile/PDF/PDFNotes.swift" \
    "$project_directory/Sources/Remile/PDF/PDFEditing.swift" \
    "$project_directory/Tests/PDFSignatureChecks/main.swift" > "$check_directory/signature-checks.swift"
swift -module-cache-path "$check_directory/module-cache" "$check_directory/signature-checks.swift" "$check_directory"
# Independent offline digest verification. Trust/revocation validation is deliberately excluded.
for file in "$check_directory"/{signed,annotated,twice,overwrite}-p{0,3}.pdf; do
    result="$(pdfsig -nocert -no-ocsp "$file" 2>&1)"
    print -r -- "$result"
    [[ "$result" == *'Signature Validation: Signature is Valid.'* ]] || exit 1
done
