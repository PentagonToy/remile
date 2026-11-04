#!/bin/zsh
# Optional synthetic collaboration scenarios. Never connects to an Overleaf account.
set -euo pipefail
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an absolute external output directory}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
case "$check_directory" in "$project_directory"|"$project_directory"/*) exit 1 ;; esac
cd "$project_directory"
REMILE_OVERLEAF_COLLABORATION_CHECKS=1 swift test --build-system native --scratch-path "$check_directory" --jobs 2 --filter 'OverleafGitSyncTests.test(SameParagraphConcurrentEditsConvergeThroughGit|ContinuedTypingAndNewLastLineConvergeThroughGit|FileLifecycleAndOfflineRestartConvergeThroughGit)'
