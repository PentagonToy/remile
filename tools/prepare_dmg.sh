#!/bin/zsh
# Package an already built app. Publication and notarisation are separate steps.
set -euo pipefail
application="${1:?Provide an absolute remile.app path}"
output_directory="${2:?Provide an absolute output directory}"
source_directory="${0:A:h:h}"
case "$application:$output_directory" in /*:/*) ;; *) exit 1 ;; esac
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$application/Contents/Info.plist")
architectures=$(/usr/bin/lipo -archs "$application/Contents/MacOS/Remile")
case "$architectures" in arm64|x86_64) architecture="$architectures" ;; *) print -u2 'Expected one supported architecture.'; exit 1 ;; esac
mkdir -p "$output_directory"
disk="$output_directory/remile-$version-$architecture.dmg"
[[ ! -e "$disk" ]] || { print -u2 'DMG already exists; choose a new output directory.'; exit 1; }
work=$(mktemp -d "$output_directory/dmg-work.XXXXXX")
mount=""
mounted=false
cleanup() {
  if $mounted; then
    if ! hdiutil detach "$mount" >/dev/null 2>&1; then
      print -u2 "Temporary image remains mounted at $mount; detach it before removing $work."
      return
    fi
  fi
  rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/staging" "$work/module-cache"
codesign --verify --deep --strict "$application"
ditto "$application" "$work/staging/remile.app"
ln -s /Applications "$work/staging/Applications"
swift -module-cache-path "$work/module-cache" "$source_directory/tools/dmg_layout.swift" background "$work/staging/.background.tiff"
hdiutil create -volname "remile. $version" -srcfolder "$work/staging" -fs HFS+ -format UDRW "$work/working.dmg"
hdiutil attach -nobrowse -noautoopen -noverify -readwrite -plist "$work/working.dmg" > "$work/attach.plist"
for index in {0..8}; do
  if volume=$(/usr/libexec/PlistBuddy -c "Print :system-entities:$index:mount-point" "$work/attach.plist" 2>/dev/null); then
    mount="$volume"
    break
  fi
done
[[ -n "$mount" ]] || { print -u2 'Could not locate the mounted installer volume.'; exit 1; }
mounted=true
clang -Wno-deprecated-declarations -framework CoreServices "$source_directory/tools/dmg_alias.c" -o "$work/dmg-alias"
"$work/dmg-alias" "$mount/.background.tiff" "$work/background-alias"
swift -module-cache-path "$work/module-cache" "$source_directory/tools/dmg_layout.swift" layout "$mount" "$work/background-alias"
hdiutil detach "$mount"
mounted=false
hdiutil convert "$work/working.dmg" -format UDZO -o "$disk"
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
