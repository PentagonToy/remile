<picture>
  <source media="(prefers-color-scheme: dark)" srcset="others/banners/remile_banner_dark.svg">
  <img src="others/banners/remile_banner_light.svg" alt="remile." width="960">
</picture>

# remile.

> Across time, a few words find you here.

A quiet, local document workspace to organise your thoughts through writing and leave a record you can return to.

## Read, write and find

- **Markdown** — Write in Edit, read the rendered document, or keep both together in Split.
- **PDF** — Read, annotate and search across your local PDF library, with matching passages beside the page.
- **LaTeX** — Edit multi-file projects, navigate their outline, compile and preview the PDF.
- **Overleaf** — Work on a local copy and review changes before synchronising with your online project.
- **AI** — Use Apple Intelligence on your Mac or connect ChatGPT for document questions, word alternatives, grammar suggestions and reviewed LaTeX repairs.

Convert, compress, combine and export documents when you need to. Suggested source changes stay reviewable and undoable.

[Install & updates](docs/distribution.md) · [Features](docs/features.md) · [AI & writing](docs/assistant.md) · [CLI](docs/cli.md) · [Brand](docs/brand.md)

## Begin with a document

Open a Markdown file or PDF, return to a recent document, or bring a LaTeX project into the workspace. Add a folder to Library when you want to find passages across your documents. Your files stay on your Mac; you choose when to connect AI or synchronise with Overleaf.

## Development

remile. is a native Swift application for macOS 14 and later. The Swift package has no external package dependencies. AI features depend on supported system capabilities or a connected ChatGPT account. Local LaTeX compilation uses your installed TeX tools, and Overleaf synchronisation requires Git access to the project.

Sources live in `Sources/Remile`. `tools/prepare_app.sh` builds and packages `remile.app`. Set `REMILE_BUILD_DIRECTORY` to an external output directory. Focused checks live in `Tests` and `tools/check_*.sh`.

## Licence and acknowledgements

remile. source code is available under the [MIT licence](LICENSE).

The ChatGPT icon path is reused from [OpenCode](https://github.com/anomalyco/opencode) under MIT, with its original notice retained. See [third-party notices](THIRD_PARTY_NOTICES.md) for this asset, platform components, external tools and the distinction between incorporated material and development references. Apple, OpenAI and Overleaf names and marks remain their owners’ property. remile. is an independent project.
