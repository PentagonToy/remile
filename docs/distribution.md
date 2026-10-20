# Install and updates

remile. 0.1.0 targets macOS 14 and later. The Apple Silicon DMG is published on [GitHub releases](https://github.com/PentagonToy/remile/releases).

For DMG installation, drag remile.app to Applications. The app includes its [CLI](cli.md). Settings → General shows the installed version and checks for updates when requested. A newer stable release with a matching DMG opens its download in the browser. The app does not replace itself. No document content or account credentials are included in the GitHub check.

If macOS blocks opening the app, consult [Apple’s downloaded-app guidance](https://support.apple.com/en-au/102445) and verify that your copy came from this project’s release. Quit remile. before upgrading.

## Build and package

`VERSION` records the package version. Run `tools/prepare_app.sh` with `REMILE_BUILD_DIRECTORY` set to an external build directory. It packages the native app, licences, artwork and CLI. Local builds use an ad hoc signature. Set `REMILE_SIGN_IDENTITY` to the authorised Developer ID Application identity for a release build; that path enables the hardened runtime and timestamp. Before public distribution, notarise and staple the app, verify it on a clean Mac and retain the exact source identity and checksums. Ad hoc builds can require renewed Keychain approval after replacement and are not notarised release artefacts.

`tools/prepare_dmg.sh /absolute/remile.app /absolute/output` packages an existing app and writes `remile-VERSION-ARCH.dmg`, `SHA256SUMS` and a draft `remile.rb` cask with the actual DMG checksum. It does not publish a release. Upload the tested DMG under the corresponding `vVERSION` tag only after review. The draft cask URL expects that exact release asset name.

## Homebrew

```sh
brew install --cask PentagonToy/tap/remile
brew upgrade --cask remile
```

The [project tap](https://github.com/PentagonToy/homebrew-tap) installs the native app and bundled CLI. The versioned cask verifies the released DMG checksum. The 0.1.0 package uses an ad hoc signature and has not been notarised by Apple. Homebrew installation does not grant an exception to macOS security checks. No cask hook removes quarantine or disables Gatekeeper.


For a Homebrew installation, update through Homebrew rather than mixing package-manager updates with manual app replacement. The in-app check remains a link to published release assets.
