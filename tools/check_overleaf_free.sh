#!/bin/zsh
# Compatibility entry for the standard Git-only transport checks.
set -eu
exec zsh "${0:A:h}/check_overleaf_git.sh" "${1:?Provide an external output directory}"
