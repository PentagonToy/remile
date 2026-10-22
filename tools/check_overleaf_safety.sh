#!/bin/zsh
# Synthetic local checks only. Never connects to an Overleaf account.
set -euo pipefail
project_directory="${0:A:h:h}"
check_directory="${1:?Provide a new absolute external output directory}"
python_path="${2:?Provide the current host Python executable}"
case "$check_directory" in /*) ;; *) print -u2 "Use an absolute output directory."; exit 1 ;; esac
if [[ -e "$check_directory" ]]; then print -u2 "Use a new output directory to isolate fixtures."; exit 1; fi
mkdir -p "$check_directory"
checks=(git comments connection realtime titlebar)
for check in "${checks[@]}"; do
    case "$check" in
        git) script=check_overleaf.sh ;;
        comments) script=check_overleaf_comments.sh ;;
        connection) script=check_overleaf_connection.sh ;;
        realtime) script=check_overleaf_realtime.sh ;;
        titlebar) script=check_titlebar.sh ;;
    esac
    print "Checking $check…"
    if ! zsh "$project_directory/tools/$script" "$check_directory/$check" "$python_path" > "$check_directory/$check.log" 2>&1; then
        print -u2 "FAILED: $check · see $check_directory/$check.log"
        exit 1
    fi
    print "PASS: $check"
done
"$python_path" - "$project_directory" "$check_directory" <<'PY'
import json, subprocess, sys
from pathlib import Path
root, output = map(Path, sys.argv[1:])
result = {'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(), 'scope': 'synthetic-local-only', 'working_tree_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=root, text=True).strip()), 'checks': {name: 'passed' for name in ['git', 'comments', 'connection', 'realtime', 'titlebar']}, 'live_overleaf_tested': False}
(output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
print('All five Overleaf safety groups passed; no live account was contacted.')
PY
