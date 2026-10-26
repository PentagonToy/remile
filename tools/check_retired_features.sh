#!/bin/zsh
set -eu
root="${0:A:h:h}"
output="${1:?Provide an external output directory}"
case "$output" in /*) ;; *) exit 1 ;; esac
[[ "$output" != "$root" && "$output" != "$root"/* ]] || exit 1
mkdir -p "$output/module-cache"
cat "$root/Sources/Remile/App/KeychainAccess.swift" "$root/Sources/Remile/App/RetiredPublisherSession.swift" "$root/Tests/RetiredFeatureChecks/main.swift" > "$output/checks.swift"
swift -module-cache-path "$output/module-cache" "$output/checks.swift"
