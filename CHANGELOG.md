# Changelog

## Unreleased

## 0.1.2 — 2026-10-21

- Add PDF drawing, rectangles and ellipses, with colour selection and Undo. Defer annotation serialisation until Save and preview strokes as vector overlays.
- Add signature editing locks and explicit risk consent in PDF readers and Search. Preserve original signed bytes for supported, permitted incremental annotation saves; retain one temporary original during editing and clean it after Save or Discard. Integrity checks do not validate certificate trust, expiry or revocation.
- Group each highlight selection into one annotation per page, including inline maths. Preserve form data and support undoable highlight and comment-thread deletion.
- Consolidate page overview actions into one toolbar with PDF addition, paper size and selection-aware rotation. Adapt narrow PDF, LaTeX and Home layouts; align tool icons, hit areas and accessibility labels.
- Simplify AI settings, add an app-wide Work offline switch and improve document evidence for Ask. Add read-only `pdf-read` CLI context, including unsaved annotations.
- Automatically publish local Overleaf edits in Online mode while the project is open, pausing for remote-change review. Show project tags, minute-based sync ages and connection-specific recovery actions.
- Add a first-run tour with replay from User guide. Align guide cards, shorten descriptions, strengthen text contrast and use paper-coloured PDF and Markdown chrome. Slow tour and offline flight transitions, respecting animation preferences and Reduce Motion.
- Add LaTeX compilation time limits and environment checks, dependency guidance and reviewed ChatGPT diagnostic advice. Support MacTeX Ghostscript for EPS preparation and asset previews.
- Preserve reader position when opening panels and completed search results when returning from a document. Add complete per-folder reindexing and smooth native mouse-wheel scrolling.
- Bound temporary compilation storage and session caches. Consolidate documentation around current workflows, installation and limits.

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
