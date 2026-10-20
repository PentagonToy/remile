<picture>
  <source media="(prefers-color-scheme: dark)" srcset="others/banners/deerstalker_banner_dark.svg">
  <img src="others/banners/deerstalker_banner_light.svg" alt="Deerstalker" width="100%">
</picture>

# Deerstalker

A local document workspace for reading, creating and searching PDFs, with a Markdown reader and editor.

Home prioritises opening documents and recent reading, with **Convert**, **Compress** and **Combine** as supporting tools and library **Search** in the sidebar. Convert accepts mixed images, supported Word documents and rendered Markdown, with per-file previews and separate PDF outputs. Compress offers Color/Grayscale and three image-quality presets, actual size comparison and previews. Open a document, drop it outside the tool cards or return to a recent file. Drop supported files onto Convert, one PDF onto Compress, or multiple PDFs onto Combine to prepare that operation. See [Home and local search](docs/home-and-search.md) for the current source implementation and limits.

## Goals

- Read PDFs smoothly with substantially lower memory use than Adobe Acrobat. Verify this goal by comparing the same documents under comparable conditions.
- Select and copy PDF text normally, with no external application required for reading or copying.
- Open Markdown documents in a rendered reading view by default. Offer an editing mode and a split view with the Markdown source and rendered preview side by side.
- Make PDF annotations and comments intuitive, taking inspiration from the clarity of Apple Messages: make it easy to see what a comment refers to, read its conversation and reply.

The project has a locally installed macOS prototype; these goals describe intended behaviour, not completed features. See [architecture and current limits](docs/architecture.md) and [follow-up work](docs/TODO.md).

## Reading controls

PDF and Markdown views, including search previews, provide visible zoom-out, percentage, zoom-in and Fit controls. Visible buttons change zoom by ten percentage points; Command-plus/minus adjusts by two percentage points. The percentage menu offers actual size and width/page fitting where applicable. Settings group appearance and default Markdown zoom under General, with response detail and conversation retention under Ask.

PDF and Markdown open inside the main window. Home navigation and native window close protect unsaved changes; Command-S saves and Shift-Command-S saves a copy. Markdown defaults to Read, with Edit and a resizable source/preview Split view.

Deerstalker no longer connects to Baker. Normal copy uses the document's text; the application has no equation-copy adapter or Baker settings.

## Search direction

The source now provides a persistent local folder index with ranked page results, exact phrases and page navigation. Use Search → Library → Add to Library to choose the folders indexed in advance. Update Index updates changed files and removes deleted files from the index; Stop preserves committed documents for a later refresh. OCR, automatic file watching and dense semantic retrieval remain pending. On-device Explore query expansion is implemented; no separate embedding model is required for it. See [search design and verified model notes](docs/search-models.md); semantic indexing, model downloads and inference are not implemented yet.

The supplied light/dark branding lives under `others/`. The application packaging script uses the supplied light icon for the macOS app bundle; run a build only when explicitly requested.


Library Search opens in the main window with document covers, compact PDF-page/Markdown-section rows, filtering and highlighted original previews. Ask opens the same on-device Apple Intelligence conversation panel in Search and the PDF reader, with message bubbles, collapsed source lists, source-page navigation and transient passage highlights. Settings offers Low/Mid/High response detail (default Mid). Reader questions use selected and relevant extracted PDF passages; cautious general context is labelled separately. Search also supports saved PDF text highlights with the fixed Okabe–Ito palette and one-step Undo. Explore expands indirect wording into related indexed concepts, while no-hit keyword searches can offer spelling corrections. Folder indexing and retrieval stay local; relevance order is not a probability. See [Home and local search](docs/home-and-search.md) for workflow, validation and current limits.
