<picture>
  <source media="(prefers-color-scheme: dark)" srcset="others/brand/banners/remile_banner_dark.svg">
  <img src="others/brand/banners/remile_banner_light.svg" alt="remile." width="960">
</picture>

# remile.

> Across time, a few words find you here.

A local workspace for PDF, Markdown and LaTeX documents.

## Read, write and find

- **Markdown** — Write in Edit, read the rendered document, or keep both together in Split.
- **PDF** — Read, annotate and search across your local PDF library, with matching passages beside the page.
- **LaTeX** — Edit multi-file projects, navigate their outline, compile and preview the PDF.
- **Overleaf** — Work on a local copy and review changes before synchronising with your online project.
- **AI** — Use Apple Intelligence on your Mac or connect ChatGPT for document questions, [manuscript review](docs/manuscript-review.md), grammar suggestions and reviewed LaTeX repairs.

Convert, compress, combine and export documents when you need to. Suggested source changes stay reviewable and undoable.

[Install & updates](docs/distribution.md) · [Changelog](CHANGELOG.md) · [Features](docs/features.md) · [AI & writing](docs/assistant.md) · [CLI](docs/cli.md) · [Brand](docs/brand.md)

## Begin with a document

Open a Markdown file or PDF, return to a recent document, or bring a LaTeX project into the workspace. Add a folder to Library when you want to find passages across your documents. Your files stay on your Mac. You choose when to connect AI or synchronise with Overleaf.

## Install

### Homebrew

With [Homebrew](https://brew.sh) installed:

```sh
brew install --cask PentagonToy/tap/remile
```

Update with `brew upgrade --cask remile`. The cask installs the app and the `remile` CLI.

### Download

Download [remile. 0.1.3 for Apple Silicon](https://github.com/PentagonToy/remile/releases/download/v0.1.3/remile-0.1.3-arm64.dmg), open the DMG and drag **remile.app** into **Applications**. Checksums are included with the [release](https://github.com/PentagonToy/remile/releases/tag/v0.1.3).

### Requirements

| Component | Requirement |
| --- | --- |
| Mac | Apple Silicon, M1 or later. This release contains an arm64 build. |
| macOS | Targets macOS 14 Sonoma and later. Release validation used macOS 27 on an M1 Pro. |
| Reading, writing and local search | No AI account or TeX installation required. |
| LaTeX, optional | A local TeX installation with `latexmk`, such as MacTeX or TeX Live. |
| Overleaf, optional | Internet, Git and Git access to your Overleaf project. |
| Apple Intelligence, optional | macOS 26 or later on an eligible Mac, with Apple Intelligence enabled. |
| ChatGPT, optional | Internet and an eligible connected ChatGPT account. Account limits apply. |
| Package trust | Version 0.1.3 uses an ad hoc signature and is not Apple-notarised. macOS may block its first launch. |
| Licence | [MIT](LICENSE). Platform components, external tools and connected services retain their own terms. |

If macOS blocks the first launch, read [Apple’s guidance for opening downloaded apps](https://support.apple.com/en-au/102445). See [installation and updates](docs/distribution.md) for package details and the optional CLI setup after a DMG install.

## Development

remile. is a native Swift application with no external Swift package dependencies.

Sources live in `Sources/Remile`. `tools/prepare_app.sh` builds and packages `remile.app`. Set `REMILE_BUILD_DIRECTORY` to an external output directory. Focused checks live in `Tests` and `tools/check_*.sh`.

## Licence and acknowledgements

remile. source code is available under the [MIT licence](LICENSE).

The ChatGPT icon path is reused from [OpenCode](https://github.com/anomalyco/opencode) under MIT, with its original notice retained. See [third-party notices](THIRD_PARTY_NOTICES.md) for this asset, platform components, external tools and the distinction between incorporated material and development references. Apple, OpenAI and Overleaf names and marks remain their owners’ property. remile. is an independent project.
