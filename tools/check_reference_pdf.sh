#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
export REMILE_REFERENCE_CHECK_MAIN="$project_directory/Tests/ReferencePDFChecks/main.swift"
exec zsh "$project_directory/tools/check_references.sh" "$@"
