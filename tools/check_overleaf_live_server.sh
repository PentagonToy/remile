#!/bin/zsh
# Explicit real-server mutation check. Stop other Live writers before running.
set -euo pipefail
[[ "${REMILE_LIVE_SERVER_CHECK_PROJECT:-}" == remile_sample ]] || { print -u2 'Set REMILE_LIVE_SERVER_CHECK_PROJECT=remile_sample only after authorising this real-project check.'; exit 1; }
source_directory="${0:A:h:h}"
output="${1:?Provide a fresh absolute evidence directory under Agents/Repository}"
application="${2:?Provide an already built remile.app}"
case "$output" in /Volumes/PentagonToy/Workspace/Agents/Repository/*) ;; *) print -u2 'Use Agents/Repository for evidence.'; exit 1 ;; esac
[[ ! -e "$output" ]] || { print -u2 'Use a fresh output directory.'; exit 1; }
umask 077
mkdir -p "$output/module-cache" "$output/helper"
codesign --verify --deep --strict "$application"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$application/Contents/Info.plist")" == local.remile.app ]] || { print -u2 'Provide a built remile.app.'; exit 1; }
paths=("$source_directory"/Sources/Remile/**/*.swift(.N))
paths=("${(@)paths:#*/App/RemileApp.swift}")
for source_path in "${paths[@]}" "$source_directory/Tests/OverleafLiveServerChecks/main.swift"; do
  cat "$source_path"
  print '\n'
done > "$output/main.swift"
swiftc -O -whole-module-optimization -module-cache-path "$output/module-cache" "$output/main.swift" -o "$output/server-check"
ditto "$application" "$output/helper/remile.app"
cp "$output/server-check" "$output/helper/remile.app/Contents/MacOS/Remile"
codesign --force --deep --sign - "$output/helper/remile.app"
codesign --verify --deep --strict "$output/helper/remile.app"
"$output/helper/remile.app/Contents/MacOS/Remile" "$output"
# Retain failure evidence for manual recovery. Successful runs remove only their own probes.
rm -rf "$output/module-cache" "$output/helper"
