#!/bin/zsh
# Explicit native build entry point; do not run without a requested build.
set -euo pipefail
source_directory="${0:A:h:h}"
output_directory="${REMILE_BUILD_DIRECTORY:-/Volumes/PentagonToy/Workspace/Agents/Repository/remile/local-build}"
case "$output_directory" in /*) ;; *) print -u2 "Use an absolute output directory."; exit 1 ;; esac
mkdir -p "$output_directory"
cd "$source_directory"
swift build --build-system native --scratch-path "$output_directory/swift-build" -c release --product Remile
binary_directory="$(swift build --build-system native --scratch-path "$output_directory/swift-build" -c release --show-bin-path)"
application="$output_directory/remile.app"
mkdir -p "$application/Contents/MacOS" "$application/Contents/Resources"
mkdir -p "$application/Contents/Resources/Brand"
cp others/banners/*.svg others/icons/*.svg "$application/Contents/Resources/Brand/"
cp "$binary_directory/Remile" "$application/Contents/MacOS/Remile"
swift tools/render_icons.swift others/icons/remile_icon_light_rounded.svg "$output_directory/Remile.iconset"
iconutil -c icns "$output_directory/Remile.iconset" -o "$application/Contents/Resources/Remile.icns"
cat > "$application/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.remile.app</string>
<key>CFBundleName</key><string>remile.</string>
<key>CFBundleDisplayName</key><string>remile.</string>
<key>CFBundleExecutable</key><string>Remile</string>
<key>CFBundleIconFile</key><string>Remile.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>local.remile.pdf-page</string>
<key>UTTypeDescription</key><string>remile. page position</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
</dict></array>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>PDF and Markdown documents</string>
<key>CFBundleTypeRole</key><string>Editor</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>com.adobe.pdf</string><string>net.daringfireball.markdown</string><string>public.plain-text</string></array>
</dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$application"
print "$application"
