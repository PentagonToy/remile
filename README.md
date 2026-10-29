<picture>
  <source media="(prefers-color-scheme: dark)" srcset="others/brand/banners/remile_banner_dark.svg">
  <img src="others/brand/banners/remile_banner_light.svg" alt="remile." width="960">
</picture>

# remile.

> Across time, a few words find you here.

A local workspace for PDF, Markdown and LaTeX documents.

## Read, write and find

- **Writer** — Write paged documents, edit supported DOCX content and export a PDF copy.
- **Markdown** — Write in Edit, read the rendered document, or keep both together in Split.
- **PDF** — Read, annotate and search across your local PDF library, with matching passages beside the page.
- **LaTeX** — Edit multi-file projects, navigate their outline, compile and preview the PDF.
- **Overleaf** — Start in Live for online editing, or use Private to review local changes before publishing.
- **Reference** — Organise PDF/BibTeX records, review duplicates and keep citation keys with shared attachments. See [Reference](docs/reference.md).
- **AI** — Use Apple Intelligence on your Mac or connect ChatGPT for document questions, [manuscript review](docs/manuscript-review.md), grammar suggestions and reviewed LaTeX repairs.

Convert, compress, combine and export documents when you need to. Suggested source changes stay reviewable and undoable.

[Website](https://pentagontoy.github.io/remile/) · [Install & updates](docs/distribution.md) · [Changelog](CHANGELOG.md) · [Features](docs/features.md) · [AI & writing](docs/assistant.md) · [CLI](docs/cli.md) · [Brand](docs/brand.md)

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

Download [remile. 0.2.1 for Apple Silicon](https://github.com/PentagonToy/remile/releases/download/v0.2.1/remile-0.2.1-arm64.dmg), open the DMG and drag **remile.app** into **Applications**. Checksums are included with the [release](https://github.com/PentagonToy/remile/releases/tag/v0.2.1).

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
| Package trust | Developer ID signed and Apple-notarised. macOS may ask you to confirm the first launch. |
| Licence | [MIT](LICENSE). Platform components, external tools and connected services retain their own terms. |

See [installation and updates](docs/distribution.md) for package details and the optional CLI setup after a DMG install.

## Development

The source branch includes changes after the latest packaged release, including PDF Slide View, Reference key locks and additional reference types. See [Unreleased changes](CHANGELOG.md#unreleased). Download links above continue to select the published 0.2.1 package.

remile. is a native Swift application with no external Swift package dependencies.

Sources live in `Sources/Remile`. `tools/prepare_app.sh` builds and packages `remile.app`. Set `REMILE_BUILD_DIRECTORY` to an external output directory.

Use a full Xcode installation for XCTest. Command Line Tools alone do not include it. Run the standard tests with an external build directory:

```sh
swift test --build-system native --scratch-path /absolute/path/to/remile-tests --jobs 2
```

If Command Line Tools are selected, prefix the command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, using your Xcode installation path. This selects Xcode for that command without changing the system setting.

`Tests/RemileTests` covers CLI argument validation, reference types and Markdown rendering, resource confinement and MathML. It imports the app module directly and uses isolated temporary fixtures. Open `Package.swift` in Xcode to run these XCTest cases there. The existing `tools/check_cli_arguments.sh` and `tools/check_markdown.sh` entry points run the corresponding tests.

The Swift workflow builds the release executable and runs the standard tests and Live sync regression checks on macOS for relevant pushes to `main` and for pull requests. It does not sign, notarise or publish the app. Other focused checks remain in `Tests` and `tools/check_*.sh`. Run the checks for the behaviour you change. The CI selection does not replace the full regression suite or interactive release checks.

## Licence and acknowledgements

remile. source code is available under the [MIT licence](LICENSE).

The ChatGPT icon path is reused from [OpenCode](https://github.com/anomalyco/opencode) under MIT, with its original notice retained. See [third-party notices](THIRD_PARTY_NOTICES.md) for this asset, platform components, external tools and the distinction between incorporated material and development references. Apple, OpenAI and Overleaf names and marks remain their owners’ property. remile. is an independent project.
