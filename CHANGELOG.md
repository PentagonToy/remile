# Changelog

Changes are recorded here before release notes are published. Unreleased entries are work in progress, rather than features available in the current download.

## 0.1.1 — 2026-10-20

- Place larger LaTeX and Overleaf titles in a bounded, subtle box at the centre of the action toolbar. Centre titles that fit and keep the beginning of overflowing titles visible. Double-click an Overleaf title to rename the online project after server confirmation.
- Show Overleaf sync age in whole minutes.
- Resize Files and Outline by dragging their dividing line.
- Preview PDF, EPS and image assets directly from Files, alongside the compiled document. EPS previews use temporary copies and require `epstopdf`.
- Centre the empty Comments state and remove the redundant heading.
- Dismiss inline title and file-name editing when clicking elsewhere.
- Align the Export icon on a fixed canvas at 18pt Heavy, raised by 2.2pt.
- Mark Overleaf projects with a leaf badge on the recent document icon.
- Remove superseded build caches and bound abandoned build caches to seven days or 512 MB, while protecting active builds. Project copies, unsaved drafts and editing history are separate.

## 0.1.0 — 2026-10-20

First public macOS release for Apple Silicon.

- Read and edit Markdown, annotate PDFs, and search an indexed local library.
- Edit multi-file LaTeX projects with compilation, PDF preview, outline, source navigation and local history.
- Connect Overleaf projects through local copies and review changes before synchronising.
- Choose Apple Intelligence, ChatGPT or Manual for writing assistance. Review grammar and word suggestions before applying them.
- Create files, folders and virtual collections from the Files sidebar. Rename items inline and distinguish the main document.
- Open independent windows, including New Window from the Dock menu.
- Install through the DMG or the `PentagonToy/tap/remile` Homebrew cask.

The 0.1.0 package is ad hoc signed and is not Apple-notarised.
