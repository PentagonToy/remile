#!/bin/zsh
set -eu
project_directory="${0:A:h:h}"
check_directory="${1:?Provide an absolute external output directory}"
python_path="${2:?Provide the current host agent Python}"
case "$check_directory" in /*) ;; *) exit 1 ;; esac
exec "$python_path" "$project_directory/Tests/MarkdownRemoteImageChecks/run.py" "$project_directory" "$check_directory"
