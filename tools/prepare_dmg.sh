#!/bin/zsh
# Package an already built app. Publication and notarisation are separate steps.
set -euo pipefail
application="${1:?Provide an absolute remile.app path}"
output_directory="${2:?Provide an absolute output directory}"
case "$application:$output_directory" in /*:/*) ;; *) exit 1 ;; esac
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$application/Contents/Info.plist")
architectures=$(/usr/bin/lipo -archs "$application/Contents/MacOS/Remile")
case "$architectures" in arm64|x86_64) architecture="$architectures" ;; *) print -u2 'Expected one supported architecture.'; exit 1 ;; esac
mkdir -p "$output_directory"
disk="$output_directory/remile-$version-$architecture.dmg"
[[ ! -e "$disk" ]] || { print -u2 'DMG already exists; choose a new output directory.'; exit 1; }
staging=$(mktemp -d "$output_directory/dmg-stage.XXXXXX")
trap 'rm -rf "$staging"' EXIT
codesign --verify --deep --strict "$application"
ditto "$application" "$staging/remile.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "remile. $version" -srcfolder "$staging" -ov -format UDZO "$disk"
checksum=$(shasum -a 256 "$disk" | cut -d ' ' -f 1)
cat > "$output_directory/remile.rb" <<CASK
cask "remile" do
  version "$version"
  sha256 "$checksum"
  url "https://github.com/PentagonToy/remile/releases/download/v#{version}/remile-#{version}-$architecture.dmg"
  name "remile."
  desc "Local document workspace for reading, writing and library search"
  homepage "https://github.com/PentagonToy/remile"
  depends_on macos: :sonoma
  depends_on arch: :$architecture
  app "remile.app"
  binary "#{appdir}/remile.app/Contents/Resources/CLI/remile"
end
CASK
print "$checksum  ${disk:t}" > "$output_directory/SHA256SUMS"
print "$disk"
