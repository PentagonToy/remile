# Features

## Documents

Home opens PDF and Markdown documents or a local LaTeX project. Recent entries carry TeX, MD or PDF badges. Right-click a recent entry to reveal its file in Finder or remove it from the list. The version sits beside the sidebar wordmark. Settings opens General, AI and LaTeX preferences; General includes the installed version and an update check.

Convert images, Word and Markdown to PDF. Compress PDFs with colour and quality controls, compare the result and save a separate PDF. Combine PDFs in the chosen page order. Combine Markdown files by appending their sources in the chosen order and save as `.md`. The combination window accepts one format at a time. Suggested output names use `converted_`, `compressed_` or `combined_` before the original filename.

The User guide is available from the Home sidebar and Help → remile. User Guide. It opens with AI, document privacy and library search. More features expands the complete reference. It is not shown automatically on first launch. Recent-document cards show names and dates without file-path hover labels.

## PDF

Switch between one-page and two-page views with the layout button. Two-page view pairs pages from the beginning: 1–2, 3–4 and so on. Enter a page number to navigate directly.

The sidebar provides pages, outline, search, highlights and comments. Select text to copy, highlight, annotate or translate. Scan & OCR recognises text with Apple Vision. Edit PDF provides text, annotation and page controls. Undo reverses editing operations; Save writes the document. Export comments from the Comments sidebar as Markdown or JSON, retaining page, author, text and reply relationships.

## Markdown

Read, Edit and Split share one source buffer. Outline folds above the brand footer. Editor settings control line numbers, source font size, spelling and live preview. Preview zoom adjusts the rendered document independently. Local Markdown images and HTML `<img>` and `<picture>` images appear in the preview and PDF export. Light and dark picture variants follow the reader appearance; PDF export uses the light fallback. Passive SVG artwork is supported alongside raster images. Keep images in the document folder or its subfolders; remote images require a local copy. Scripts, embedded content and SVG stylesheets are not supported.

Maths completion provides TeX commands and environment blocks. Tab accepts a candidate; Escape dismisses it. Spelling and grammar suggestions exclude source syntax and formulae. Double-click an underlined word to show corrections below it. Select a correction to apply an undoable edit. A correct prose word offers on-device single-word synonyms. Suggestions appear on demand, preserve source syntax and apply through Undo. The toolbar also lists writing suggestions.

Format provides inline styles, links, lists, maths, code and table editing. Spreadsheet paste creates a Markdown table. Paste as Markdown retains bold, italic and links from formatted clipboard text. Pasting a URL over selected text creates a link. Share exports the current source to PDF.

## LaTeX

Open a project folder, select its main document and compile. Project settings control the engine, binary directory, editor theme, font size and history interval. Missing TeX tools open a compact installation guide. pdfLaTeX prepares EPS graphics in the build snapshot through restricted epstopdf conversion.

Files and Outline fold independently. Outline follows literal input, include and subfile links from the main document and jumps to the correct source file. Dynamic TeX paths are not evaluated. Sidebar artwork can be hidden in Settings. Virtual collections use a stacked icon and a collection label. Nest collections without changing source paths. Select files with Cmd or Shift, then drag the selection or use Move to collection. Add files also accepts multiple selections. Removing a collection preserves its files and nested collections. Rename files or the project inline. SyncTeX connects source lines and PDF locations. Cmd+/ toggles comments; Tab and Shift+Tab adjust source indentation.

Compile offers a fresh rebuild and a submission comparison. The comparison checks the current source and a bibliography-embedded variant in separate snapshots, with progress and logs for each result. Embed bibliography presents the source change for review. Remove notes (%) removes author comments while preserving captions and TeX directives.

History follows edits at the selected interval and coalesces small changes. Save, navigation and source tools preserve checkpoints. Tool changes carry Before/After markers. The recent-items menu can move local editing history to Trash.

## Overleaf

Home → Overleaf offers Add new project to library and Open library. Save the account’s Git token once in Keychain. Sign in to list available projects on the left, then select projects to add to the local library on the right. A project link provides a direct alternative. Removing a project moves its local copy to Trash and retains the saved account and online project.

Overleaf uses the same native source editor, compiler, PDF preview and virtual collections as local LaTeX. Local drafts save automatically. The active project checks its remote revision every 30 seconds. Check changes opens a comparison with highlighted lines and a combined preview. Green marks agreement, orange marks mergeable differences and red marks overlapping edits. Resolve conflicting files explicitly, then update the local copy or publish the reviewed result. Changes to either revision invalidate the comparison. Matching revisions do not create a review copy. Connected projects use Git revisions rather than a second local editing history.

The title distinguishes online, offline and a locked saved connection. Work offline pauses remote requests. Git synchronisation does not join the web editor’s live cursor and presence channel; published edits remain in project history. Comments use a native bubble view and export as Markdown or JSON with replies, authors, timestamps and resolution state. The account’s saved web session supplies project-list and comment access. A short sign-in window handles authentication; documents stay in the native editor.

## ChatGPT

Home → Settings connects an eligible ChatGPT plan through official sign-in, without an API key or a separate agent runtime. Credentials stay in Keychain. Luna is selected from the account’s available catalogue by default.

The AI button opens a provider menu. Manual uses a pen symbol. An orange dot on Apple Intelligence means ChatGPT has fallen back automatically. The same provider serves PDF, search and Markdown questions. Apple Intelligence takes over when offline or when the local or server allowance is reached. ChatGPT receives the question and retrieved excerpts when you ask. Both providers use the same source attribution and conversation controls.

Each compiler error or warning offers Suggest fix beside its source location. A small review shows the diagnostic and proposed change. Apply and compile uses the editor’s Undo path; the eye button colours changed text. Offline suggestions are dimmed with a short hover label. Edits require an exact match against the unchanged source and remain undoable. Source changes mark earlier compilation output as a previous build; recompile to refresh it. Settings enables ChatGPT word alternatives and grammar suggestions on demand. Live completions stay on-device. Settings also shows local daily request and returned token counts, an adjustable app request limit and a link to ChatGPT’s account usage. Repeated word requests and unchanged diagnostic suggestions reuse bounded session caches. Document questions use one ChatGPT inference request. Requests do not create ChatGPT conversation history.

## Windows

Choose New Window from File or the Dock menu, or press ⇧⌘N. Each window keeps its own document, search and unsaved changes. Save and document commands follow the active window. Closing a window checks its changes. Quitting checks every open window. Theme and search preferences remain shared.

Markdown and LaTeX share the same sidebar artwork and settings layout, above a 32-point bottom status row. Search uses the same settings icon and places its settings button at the bottom of the results sidebar.

## Local search and agents

Add folders to the local library and search their contents. Results retain document and page context. CLI agents can read buffers and compiler logs, apply fingerprint-checked edits and export results. The eye control colours session-only CLI edits. Source changes remain undoable. Local documents save explicitly; connected Overleaf projects also save local drafts automatically.

Explicit English questions search their substantive keywords and common word endings locally, with every remaining term required. The Question keywords label explains this interpretation. Settings → Search, also available at the bottom of the search results sidebar, controls question interpretation and spelling correction suggestions. Both start enabled and apply immediately. Ordinary keywords and quoted phrases stay literal; spelling corrections remain a visible choice. This is lexical retrieval, not cross-language or semantic search, and requires no model, extra index fields or reindexing.

Search adapts to narrow windows with Results and Preview tabs. Result counts stay on their own line and the top-200 limit has a hover explanation. Library lists each document’s indexing or OCR status, with failed documents first. Index progress reports completed files. These statuses describe the most recent index, so changed folders need Update Index. The [search evaluation](search-evaluation.md) records the current quality and resource checks, including their limits.

## Appearance and updates

The sun or moon button in the LaTeX, Markdown and PDF status bars switches directly between light and dark. Home keeps appearance in Settings → General, which offers System, Light and Dark. A change applies immediately throughout the app and is saved for the next launch. System follows macOS. PDF pages retain their document colours. General settings checks GitHub releases when requested and offers a matching stable DMG when a newer version is available. Downloads open in the browser.
