# Changelog

## Unreleased

- Import LaTeX source ZIPs from the Home card into a new chosen folder, preserving the archive and its project assets. Share bounded extraction with Overleaf imports.
- Discover open documents and explicitly target CLI requests by session UUID. Add Reference import, metadata update, attachment changes, Trash/restore and key regeneration with revision checks.

- Add the local Reference workspace with libraries/collections, PDF/BibTeX import, metadata editing, reviewed duplicate merging, public-paper lookup and revision-checked CLI access.
- Add Harbour drops, attachment markers/removal, fixed citation-key rules, configurable venue columns and shared sidebar motion. Include Search and Reference in the Home tour.
- Add portable preference import/export and role-specific split defaults. Save inline edits on an outside click and let empty new Markdown drafts close without a save question.
- Open unfinished LaTeX projects for editing even when compilation fails. Harden CLI argument validation and Overleaf Live file reconciliation, including targeted Premium Git publication and Free source imports.

## 0.1.3 — 2026-10-22
- Accept project files with any extension. Dismiss inline entries on an outside click and warn before deleting connected files. Release source and PDF navigation callbacks when leaving the editor.
- Shorten help text and wrap explanatory hints. Use event-driven CLI requests, incremental source hashes, cached search grouping, bounded raster previews and asynchronous cache cleanup. Expose resource diagnostics through the CLI.
- Use responsive shared navigation widths and an equal initial Markdown split. Remove custom word alternatives and background replacement lookups. Keep native right-click spelling corrections.
- Add source-linked manuscript review questions with masked, synthetic criteria examples, persistent project results, Markdown and JSON export, Clear and CLI access.
- Add opt-in live Overleaf text editing with preserved drafts, conflict review and exclusive project ownership.
- Distinguish connection, pause reasons, pending files and project-wide server confirmation. Preserve pending intent when the live event stream closes.
- Show a direct Private / Live selector and visible comment, library and connection controls. Review Live edits by section, combine disjoint changes and hand structure changes to explicit Git review.
- Restore source/PDF navigation, including PDF double-clicks and jumps queued before preview layout.
- Clarify PDF editing protection and note replies. Add note-icon deletion.
- Shorten tours, help and documentation. Add shared writing guidance.
- Double-click blank title-bar space to zoom and restore the window, preserving toolbar controls.
- Add token-setup hover guidance and a shared help-bubble template. Organise actual artwork by brand, symbols and motion, with verified runtime paths and a native-symbol catalogue.
- Check saved Overleaf sessions before opening login. Separate web account setup from Git tokens, validate project-list responses before completing connection, and distinguish login expiry, verification, Keychain and server failures.
- Separate saved Overleaf project management from import. Add tag filters, coloured tag marks, sorting and persistent manual ordering.
- Load remote Markdown images online through bounded, cancellable requests. Keep reading previews available offline or when images or TeX notation are unsupported, using labelled placeholders or source text.
- Make blank title-bar space draggable while preserving toolbar controls. Fill Home card rows to the banner width at wide and narrow window sizes.
- Give the disk image a drag-to-Applications layout with a paper background and installation arrow.

## 0.1.2 — 2026-10-21
- Add PDF drawing, rectangles and ellipses, with colour selection and Undo. Defer annotation serialisation until Save and preview strokes as vector overlays.
- Add signature editing locks and explicit risk consent in PDF readers and Search. Preserve original signed bytes for supported, permitted incremental annotation saves. Retain one temporary original during editing and clean it after Save or Discard. Integrity checks do not validate certificate trust, expiry or revocation.
- Group each highlight selection into one annotation per page, including inline maths. Preserve form data and support undoable highlight and comment-thread deletion.
- Consolidate page overview actions into one toolbar with PDF addition, paper size and selection-aware rotation. Adapt narrow PDF, LaTeX and Home layouts. Align tool icons, hit areas and accessibility labels.
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
