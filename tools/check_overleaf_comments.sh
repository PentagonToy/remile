#!/bin/zsh
# Compatibility entry for standard synthetic review checks. No account access.
set -euo pipefail
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an absolute external output directory}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
case "$check_directory" in "$project_directory"|"$project_directory"/*) exit 1 ;; esac
cd "$project_directory"
swift test --build-system native --scratch-path "$check_directory" --jobs 2 --filter OverleafReviewTests
