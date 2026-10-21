# Installation and updates

remile. 0.1.2 targets macOS 14 and later. The published DMG contains an Apple Silicon app and its [CLI](cli.md).

## Install

Download the DMG from [GitHub releases](https://github.com/PentagonToy/remile/releases), open it and drag remile.app to Applications. Alternatively, use the [Homebrew tap](https://github.com/PentagonToy/homebrew-tap):

```sh
brew install --cask PentagonToy/tap/remile
brew upgrade --cask remile
```

The 0.1.2 package is ad hoc signed and is not Apple-notarised. If macOS blocks its first launch, verify the download source and follow [Apple’s downloaded-app guidance](https://support.apple.com/en-au/102445). Homebrew verifies the DMG checksum and installs the app and CLI; it does not bypass macOS security checks.

## Updates

Quit remile. before replacing the app. Use Homebrew for Homebrew installations. Settings → General checks for newer stable releases and opens the matching download in a browser. This check sends no document content or account credentials. The app does not replace itself.

## Build and package

`VERSION` supplies the package version. Set `REMILE_BUILD_DIRECTORY` to an external output directory and run `tools/prepare_app.sh` to build the app with its artwork, licences and CLI. The default signature is ad hoc. `REMILE_SIGN_IDENTITY` selects a Developer ID identity with hardened runtime and timestamp; notarisation and stapling are separate operations.

Run `tools/prepare_dmg.sh /absolute/remile.app /absolute/output` to create `remile-VERSION-ARCH.dmg`, `SHA256SUMS` and a draft Homebrew cask. The installer opens with remile.app and an Applications shortcut on a paper background. Keep the tested source commit, app version and `vVERSION` release tag aligned. Publish the matching DMG and checksum, then update the tap with that checksum.
