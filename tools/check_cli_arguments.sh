#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an absolute external output directory}"
case "$check_directory" in /*) ;; *) print -u2 "Use an absolute output directory."; exit 1 ;; esac
xcrun --find xctest >/dev/null 2>&1 || { print -u2 "Select a full Xcode installation for XCTest with DEVELOPER_DIR."; exit 1; }
cd "$project_directory"
swift test --build-system native --scratch-path "$check_directory/swift-build" --jobs 2 --filter CLIArgumentTests
