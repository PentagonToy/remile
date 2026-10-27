# Install and update

remile. runs on Apple Silicon Macs with macOS 14 or later.

## Download

Open the [latest release](https://github.com/PentagonToy/remile/releases/latest), download the Apple Silicon DMG, then drag **remile.app** into **Applications**.

The app and DMG are Developer ID signed and Apple-notarised. macOS may ask you to confirm the first launch.

## Use Homebrew

```sh
brew install --cask PentagonToy/tap/remile
```

The cask installs the app and CLI. It checks the package checksum and retains macOS security checks.

## Update

Quit remile before replacing the app. For a Homebrew installation, run:

```sh
brew upgrade --cask remile
```

**Settings → General → Check for updates** opens a matching download when a newer stable release is available. It sends no document content or account credentials.

[Open your first document](getting-started.md) · [Builds, signing and packages](details/distribution.md)
