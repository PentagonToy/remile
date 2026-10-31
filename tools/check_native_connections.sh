#!/bin/zsh
# Compatibility entry for the standard synthetic account and source-safety fixtures.
set -euo pipefail
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an absolute external scratch directory}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
cd "$project_directory"
swift test --build-system native --scratch-path "$check_directory" --jobs 2 --filter NativeConnectionTests
