# Install and updates

remile. 0.1.0 targets macOS 14 and later. Release packages are being prepared; a version number in the app does not mean a public release has been uploaded. Published packages will appear on [GitHub releases](https://github.com/PentagonToy/remile/releases).

For DMG installation, drag remile.app to Applications. The app includes its [CLI](cli.md). Settings → General shows the installed version and checks for updates when requested. A newer stable release with a matching DMG opens its download in the browser. The app does not replace itself. No document content or account credentials are included in the GitHub check.

## Build and package

`VERSION` records the package version. Run `tools/prepare_app.sh` with `REMILE_BUILD_DIRECTORY` set to an external build directory. It packages the native app, licences, artwork and CLI. Local builds use an ad hoc signature. Set `REMILE_SIGN_IDENTITY` to the authorised Developer ID Application identity for a release build; that path enables the hardened runtime and timestamp. Before public distribution, notarise and staple the app, verify it on a clean Mac and retain the exact source identity and checksums. Ad hoc builds can require renewed Keychain approval after replacement and are not notarised release artefacts.

`tools/prepare_dmg.sh /absolute/remile.app /absolute/output` packages an existing app and writes `remile-VERSION-ARCH.dmg`, `SHA256SUMS` and a draft `remile.rb` cask with the actual DMG checksum. It does not publish a release. Upload the tested DMG under the corresponding `vVERSION` tag only after review. The draft cask URL expects that exact release asset name.

## Homebrew

Use a cask for the native app and its bundled CLI. A project-owned tap can distribute it once the versioned DMG has been published. The generated cask installs `remile.app` and links its CLI with the `binary` stanza, following the [Homebrew Cask Cookbook](https://docs.brew.sh/Cask-Cookbook). Submit to the main Homebrew cask repository separately when its acceptance requirements are met. No tap or public cask has been published by this work.

For an eventual Homebrew installation, update through Homebrew rather than mixing package-manager updates with manual app replacement. The in-app check remains a link to published release assets.
