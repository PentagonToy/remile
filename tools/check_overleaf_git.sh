#!/bin/zsh
# Local bare repositories and synthetic review fixtures only. No live account access.
set -euo pipefail
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an absolute external output directory}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
case "$check_directory" in "$project_directory"|"$project_directory"/*) exit 1 ;; esac
cd "$project_directory"
swift test --build-system native --scratch-path "$check_directory" --jobs 2 --filter 'Overleaf(GitSync|Source|Review|ReviewAccess|ProjectCatalogue|OnlineBar|ConnectionNotice)Tests'
