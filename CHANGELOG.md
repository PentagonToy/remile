# Changelog

## Unreleased

- Search shows local results before optional question refinement and pages beyond 200 matches. The CLI supports search offsets.
- PDF Pages uses larger previews with page numbers below. Reference gives the selected title more room.

- Show stored Reference abstracts last in a collapsed section. Remove GPT correction and the Clean up PDFs tab. Look up missing metadata and abstracts with up to three requests in progress.
- Reuse Markdown image downloads through a shared HTTP disk cache. Avoid repeated Markdown renders, cancel stale LaTeX outlines and reuse Reference PDF thumbnails. Use bounded top-candidate selection for keyword result pages.

- Reduce Live sync overhead with streaming asset checks, cancellation, unchanged-source write avoidance and stopped-session cache release. Expose pending Live sync and confirmation observations through the project CLI.

- Remove merged Reference duplicates directly while retaining PDFs and session Undo. Keep user-deleted references in Trash.

- Recover Overleaf Live automatically after brief transport loss, preserving pending edits, newer typing and Undo. Keep conflicts and account restrictions explicit. Allow switching to Private during connection startup.
- Add focused Left/Right PDF page navigation while preserving vertical scrolling and editable-field keys. Show the Apple Intelligence provider label in Ask.
- Stabilise Reference column dragging, add automatic-width reset and use spare width without replacing manual choices. Match the website's workspace navigation to Home.

- Align Ask and Reference actions, add scene-specific Workspace menu commands, improve dark Ask contrast and enlarge pane restore targets. Fit automatic Reference columns while preserving manual widths.

- Give local LaTeX the same Ask and manuscript review as connected projects. Distinguish Review manuscript from Attach Overleaf feedback and keep server Review in connected projects.

- Replace connected Overleaf Review with comments and tracked edits, distinct source highlights, full Markdown/JSON export and guarded Accept/Reject actions. Open project questions from Ask and remove the duplicate Review toolbar button.
- Reuse one recent Live project for a quick return without rejoining or recompiling. Stop hidden file checks and expire it after 45 seconds.
- Offer Default and Paper source backgrounds. Default now follows the app appearance.
- Add draft and feedback review shortcuts to Ask, project-ID review reads through the CLI and source-linked Markdown/JSON or ZIP hand-offs.
- Let unchanged Live projects connect during initial compilation. Keep Paper editor surfaces consistent and switch backgrounds with one click.
- Toggle logs and the last PDF from one toolbar button.
- Allow PDF double-click navigation after source edits and small pointer movement. Keep uncertain matches at line level.
- Remove embedded publisher sign-in and saved publisher sessions. Keep public PDF discovery and local attachment import.

## 0.1.4-beta.1 — 25 October 2026

- Add optional publisher website access with validated PDF capture, a browser fallback and opt-in session storage in this Mac's Keychain. Embedded publisher verification can still fail. No institutional login compatibility is guaranteed.
- Keep imported DOCX names and original paths. Save supported text edits without replacing unrelated Word package parts. Use a separate copy for unsupported structural changes. Separate Save from Export.
- Fill available abstracts during metadata lookup. Select several citation libraries and keep lightweight, local topic hints distinct from claim verification.
- Start Overleaf in Live unless Private was chosen. Retry transient file snapshots, reconnect from Paused and retain the source position after reviewed updates.
- Complete project image names and reference labels. Pair supported TeX environments and avoid highlighting an uncertain PDF word match.
- Align Reference headers, centre missing-value marks and distinguish DOCX with a muted rose badge.

- Preserve editors in online book metadata. Show editor-only volumes in Author / Editor and use editors for new citation keys without rewriting existing keys.

- Rank TeX citation suggestions by local sentence, title and abstract overlap. Show concise source hints without AI calls. Keep manual metadata lookup available beyond missing authors and year, with exact title matching and Crossref abstracts.

- Fill missing PDF reference metadata by DOI or arXiv ID while online, following Work offline. Preserve user fields and distinguish preprints from published papers.
- Open new LaTeX drafts before choosing a save location. Group numeric setting values beside their arrows and refine source/PDF navigation only for clear text matches.

- Open workspace help directly from User guide. Include Writer in the Home tour and respect the app animation preference during navigation.

- Unify interface type, toolbar spacing, action buttons and short selection controls across workspaces. Keep document font sizes independent. Add focused PDF and Markdown settings and shorten panel transitions while respecting Reduce Motion.

- Simplify Overleaf imports with direct project actions. Keep account preferences and Git tokens in the shared account manager.

- Create a local project from the Home LaTeX button. Keep editor names centred, align account controls and animate Overleaf navigation consistently with Search.

- Manage Overleaf account names and connections in one window. Confirm removal before deleting associated local projects and history. Size the project import window before opening it.

- Add a compact Overleaf email sign-in screen with the official web flow for other providers and additional verification. Preserve existing session storage without saving passwords.

- Copy the selected or clicked PDF table directly as spreadsheet cells, with a cancellable progress message instead of a review window.

- Drag PDF images into native editors and avoid selecting nearby text when opening an image menu. Preserve direct text selection on OCR layers.

- Copy embedded PDF image regions and copy locally recognised tables as spreadsheet cells. Share page inspection and export with the CLI.

- Copy portable Overleaf project IDs from the library and recent documents. Resolve them through CLI project discovery, source reads and explicit opening with buffer hashes and PDF currency.

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
