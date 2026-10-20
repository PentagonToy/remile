#!/bin/zsh
set -eu
exec /bin/zsh "${0:A:h}/check_responsive_editor.sh" "$@"
