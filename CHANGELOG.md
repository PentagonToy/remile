# Changelog

## Unreleased

- Switch between saved reMarkable devices. The connection window remembers your last selection and links to setup help.
- Paste TeX maths into Markdown. Preview more equations, including boxed expressions, continued fractions and annotated arrows.
- See which links open in your browser. ChatGPT sign-in can finish after you close Settings.
- Choose an Overleaf project while its tags load.
- Cancel preview and search work when you move on. Reuse PDF thumbnails and avoid rebuilding unchanged Reference lists.
- Keep editing smoothly while LaTeX updates its outline and Writer paginates.

## 0.2.6 — 13 November 2026

- Give an agent a copied document or project ID to read its source and file structure with one CLI command.

- See long LaTeX equations fit below the source, with the active `align` row highlighted. Turn the preview off in LaTeX settings.
- Preview maths completions and reuse saved equations in Markdown and LaTeX. Use Tab to move through LaTeX maths arguments.
- Edit Markdown tables with Tab, Shift+Tab and Return.
- Preview BibTeX changes in **Writing tools** and run **Submission check** on a clean project copy.
- Keep the PDF visible through LaTeX build errors. Jump from diagnostics to the source or open the full log.
- Choose separate storage and Reference folders. Reopen saved edit marks in Markdown and LaTeX, and share Overleaf edit marks through the same storage folder.
- Review and apply metadata updates for selected references, including full author lists from PDF metadata.
- Rename LaTeX and Overleaf files, folders and collections in place.
- Fit Writer pages and PDFs on opening. Keep the PDF reading position when recompiling.

## 0.2.5 — 5 November 2026

- Use **Fit** to match the page height. The zoom menu offers **Fit height** and **Fit width**.
- Open PDFs and Markdown from Finder when remile starts, without a second click in the Dock.
- Paste an article, PDF or web page link into **Find a paper…**. Save the PDF when available, the citation, or a web page with its URL and access date. Open ScienceDirect in the lookup window to capture the publisher PDF and optionally remember the sign-in on this Mac.
- Recover paper titles from embedded metadata or the first page when a PDF uses a publisher production code as its title. Review suggested corrections with **Read metadata…**.
- Search across libraries with **All references**. Collapse the library list, reMarkable, Zotero and Trash together. Use shorter empty-state messages. **Empty Trash…** is available when items or PDFs await deletion.
- Refresh the LaTeX and Overleaf file tree when compiling or syncing. Drop folders to add nested files, or list and move project files from the CLI while the editor is open.
- Use the full button area in segmented controls and sidebar rows, including Files and Review.
- Complete LaTeX and Overleaf commands after one letter, including project commands and known commands from declared packages. Show maths symbols and file paths in suggestions, and reuse existing braces. Markdown maths also suggests supported commands after one letter.
- Finish the word being typed or suggest one new word inline, preserving typed letters and handling sentence spacing and capitalisation.
- Use pdfLaTeX for Submission Check in the app and CLI, including both sides of the bibliography comparison.
- Copy saved LaTeX and Markdown IDs from **Recently opened** to find or open documents from the CLI. Copy Reference library and collection IDs to scope CLI commands.
- Choose **Online** to sync with Overleaf or **Local** to work on this Mac. **Saved** indicates a local save. Hover to see the last remote confirmation.
- Merge independent Overleaf edits and unambiguous file moves. Keep later edits and deletions when resuming a sync. Review overlapping edits or a local Git branch that changes during sync.
- Check idle open projects for collaborator edits at least once a minute during normal operation. Schedule uploads separately and report the latest Git transfer stages in the CLI.
- Reuse saved Overleaf Git tokens. Choose **Sync now** if macOS asks for Keychain approval after a rebuild or update.

## 0.2.4 — 31 October 2026

- Reliably register document windows when they attach, bring Finder-opened PDFs and Markdown to the front on launch, and keep Home hidden while the initial document loads.
- Make the optional Overleaf Review web connection an explicit choice, with revocation and CLI access checks. Git source sync remains separate.
- Run existing Overleaf CLI, login and titlebar safety checks in macOS CI. Move native account and source-safety fixtures into the standard test suite.
- Clarify release-specific notices, official ChatGPT sign-in references and the scope of source provenance checks. Add contribution, issue-reporting and security guidance. Format the touched Review code for readability.

## 0.2.3 — 31 October 2026

- Remove retired socket transport scaffolding and obsolete checks. Keep Git sync, review, recovery and source safety tests in the standard suite.
- Trim unused source-archive connection code, expose Git mode through the CLI and avoid sorting the reMarkable folder tree twice. Align connected-library search and symbols with Reference.
- Restore on-demand Overleaf project selection with collapsible tag groups, project/tag search, stable refresh and a link fallback. Selected projects still connect through Git.
- Move Overleaf source sync to Git with Online and On-device modes, grouped edits and resumable recovery. Review remains a separate web connection, with recoverable suggestion rejection.
- Merge independent concurrent Overleaf edits with one bounded retry, check active projects sooner and preserve the source caret using unique nearby text.
- Reduce Git waits and duplicate attachment reads. Check recovery space, limit managed records and prepare validation off the main thread while protecting new edits.
- Add bottom source tabs and keyboard navigation, optional line numbers, clearer save states and named, selectable review cards. Open additional PDFs without briefly showing Home.
- Read selected reMarkable folders over SSH with a local Keychain connection. Preserve original unmarked PDFs and keep updates on request.
- Import local Zotero libraries and collections. Preserve local fields, citation keys and PDF edits during source updates.
- Add Thesis / Dissertation types, degree-aware PDF metadata and exact public title matching. Correct journal mastheads stored as titles.
- Refine source selection, Reference libraries, duplicate review, shared PDF storage and connected citations.
- Bring compiler status dots closer to their icons and keep optional connection tools in one menu.
- Replace bundled Overleaf artwork with the native leaf symbol. Retain the first-use notice and the separate review of unofficial service interfaces.

## 0.2.2 — 29 October 2026

- Keep PDF Fit fixed through sidebar and window changes. Add thumbnail page deletion with Undo, full-screen Slide View and smoother bottom-tab navigation.
- Return to the matching PDF passage when a Search result is selected again, while retaining cached documents and ordinary manual scrolling.
- Fit Reference columns in smaller panes. Edit and lock citation keys, carry edits between Details and BibTeX, and recognise web, news and report types. Use a podium for conference papers.
- Widen Home navigation hit areas, align indexing feedback, prevent blank Markdown preview flashes and refine LaTeX and Writer entry.
- Reduce repeated PDF, search, Reference and Overleaf processing. Harden CLI cancellation and response handling.
- Add macOS build CI and standard tests for CLI validation, Markdown rendering, Reference layout and PDF actions.

## 0.2.1 — 27 October 2026

- Add source Find and Replace with case, whole-word and regular-expression options, plus broader local LaTeX completion.
- Open PDFs in adaptive bottom tabs, support canvas drops and remember reading positions. Improve page-key handling.
- Refine shared symbols, sidebar motion, Markdown Outline and the welcome tour.
- Reduce repeated Reference metadata work. Add library and collection renaming, and cancel empty inline name drafts.
- Correct CLI PDF status and update the workspace guides.

## 0.2.0 — 27 October 2026

- Distribute a Developer ID signed, Apple-notarised app and installer.
- Unify editor toolbars, native SF Symbols and Save/Export actions. Refine Writer controls, Reference details and narrow Markdown layouts.
- Show spelling corrections with the affected words and writing-language selection.
- Choose one storage location for Reference and Mac-specific search indexes, with verified moves applied at next launch.
- Prepare and persist ranking indexes during library updates. Show local results before optional AI refinement and browse beyond 200 matches.
- Preserve scientific search terms and highlight ranges. Separate detected bibliographies and suppress repeated PDF margins.
- Improve Overleaf Live reconnection, preserve pending edits and Undo, and reduce background work. Keep Private available for reviewed changes.
- Show connected comments and tracked edits with source links, guarded review actions and Markdown/JSON exports.
- Add local LaTeX manuscript review, automatic compilation for new drafts and conservative source/PDF navigation.
- Show Reference abstracts in a collapsed section. Retrieve available metadata and abstracts concurrently, and remove duplicate records while retaining attachments and Undo.
- Cache Markdown image downloads and Reference thumbnails. Improve PDF page previews and keyboard navigation.
- Extend CLI project discovery, review reads, search pagination and practical workflows.
- Remove embedded publisher sign-in and GPT metadata correction. Keep public-paper discovery and local PDF attachments.

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
