#!/bin/zsh
# Explicit native build entry point; do not run without a requested build.
set -euo pipefail
source_directory="${0:A:h:h}"
output_directory="${REMILE_BUILD_DIRECTORY:-/Volumes/PentagonToy/Workspace/Agents/Repository/remile/local-build}"
case "$output_directory" in /*) ;; *) print -u2 "Use an absolute output directory."; exit 1 ;; esac
mkdir -p "$output_directory"
cd "$source_directory"
version="$(cat VERSION)"
[[ "$version" =~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-beta\.([1-9][0-9]*))?$' ]] || { print -u2 'Use a numeric release version or beta.N.'; exit 1; }
bundle_version="${version%%-*}"
release_numbers=("${(@s:.:)bundle_version}")
build_suffix=999
if [[ "$version" == *-beta.* ]]; then
    build_suffix="${version##*-beta.}"
    (( build_suffix < 999 )) || { print -u2 'Beta build number is too large.'; exit 1; }
fi
build_number=$(( (release_numbers[1] * 10000 + release_numbers[2] * 100 + release_numbers[3]) * 1000 + build_suffix ))
swift build --build-system native --scratch-path "$output_directory/swift-build" -c release --product Remile
binary_directory="$(swift build --build-system native --scratch-path "$output_directory/swift-build" -c release --show-bin-path)"
application="$output_directory/remile.app"
mkdir -p "$application/Contents/MacOS" "$application/Contents/Resources"
mkdir -p "$application/Contents/Resources/Brand"
artwork=(others/brand/{icons,banners,wordmarks,scenes}/*.svg others/motion/airplane/*.svg others/symbols/{providers,integrations,reference}/*.svg)
cp "${artwork[@]}" "$application/Contents/Resources/Brand/"
mkdir -p "$application/Contents/Resources/Templates/Help"
cp others/templates/help/bubble.json "$application/Contents/Resources/Templates/Help/"
mkdir -p "$application/Contents/Resources/Templates/Review"
cp others/templates/review/criteria.json others/templates/review/question-style.md "$application/Contents/Resources/Templates/Review/"
cp others/licences/CHATGPT-LICENSE.txt "$application/Contents/Resources/Brand/"
mkdir -p "$application/Contents/Resources/Licences"
cp LICENSE "$application/Contents/Resources/Licences/Remile-MIT.txt"
cp THIRD_PARTY_NOTICES.md "$application/Contents/Resources/Licences/"
cp others/licences/SEARCH-WORDS.txt "$application/Contents/Resources/Licences/"
cp "$binary_directory/Remile" "$application/Contents/MacOS/Remile"
swift tools/render_icons.swift others/brand/icons/remile_icon_light_rounded.svg "$output_directory/Remile.iconset"
iconutil -c icns "$output_directory/Remile.iconset" -o "$application/Contents/Resources/Remile.icns"
cat > "$application/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.remile.app</string>
<key>CFBundleName</key><string>remile.</string>
<key>CFBundleDisplayName</key><string>remile.</string>
<key>CFBundleExecutable</key><string>Remile</string>
<key>CFBundleIconFile</key><string>Remile.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$bundle_version</string>
<key>RemileDisplayVersion</key><string>$version</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>local.remile.pdf-page</string>
<key>UTTypeDescription</key><string>remile. page position</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
</dict><dict>
<key>UTTypeIdentifier</key><string>local.remile.tex-items</string>
<key>UTTypeDescription</key><string>remile. source file reference</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
</dict></array>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>PDF, Markdown and Word documents</string>
<key>CFBundleTypeRole</key><string>Editor</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>com.adobe.pdf</string><string>net.daringfireball.markdown</string><string>public.plain-text</string><string>org.openxmlformats.wordprocessingml.document</string></array>
</dict></array>
</dict></plist>
PLIST
mkdir -p "$application/Contents/Resources/CLI"
cp tools/bundled_cli "$application/Contents/Resources/CLI/remile"
chmod +x "$application/Contents/Resources/CLI/remile"
signing_identity="${REMILE_SIGN_IDENTITY:-}"
local_signing=false
local_identity="$HOME/Library/Application Support/PentagonToy/Development/signing-identity"
if [[ -z "$signing_identity" && -f "$local_identity" ]]; then
    signing_identity="$(<"$local_identity")"
    local_signing=true
fi
if [[ -z "$signing_identity" || "$signing_identity" == "-" ]]; then
    codesign --force --sign - "$application"
elif $local_signing; then
    codesign --force --sign "$signing_identity" "$application"
else
    codesign --force --options runtime --timestamp --sign "$signing_identity" "$application"
fi
print "$application"
