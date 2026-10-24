# Features

## Documents and windows

Home opens PDFs, Markdown files and LaTeX projects. Recent documents show their format. A leaf badge identifies Overleaf projects. Right-click an entry to reveal its file or remove it from Recent. Convert images, Word or Markdown to PDF. Compress PDFs. Or combine files of the same format in the chosen order.

File → New Window (⇧⌘N) opens an independent workspace. Save follows the active window. Closing a document or quitting checks unsaved changes. Settings and appearance preferences are shared.

Navigation sidebars share a responsive starting width across Home, Search, PDF, Markdown, LaTeX and the Overleaf library. Drag a grip to adjust a panel. Narrow windows prioritise the document. LaTeX retains its centred initial source/PDF boundary.

A skippable tour appears on first launch. Replay it with Tour in User guide, available from Home and Help. General settings controls appearance, animations, Work offline and update checks. Reduce Motion suppresses added motion. Decorative motion stops when its window loses focus or its view closes. Slow lighthouse beams update at most 12 times per second. See [installation and updates](../distribution.md).

## PDF

Use the page field, single/two-page layout or page overview to navigate. The sidebar contains pages, outline, search, highlights and comments. Scan & OCR recognises text with Apple Vision.

Edit PDF provides notes, highlights, freehand drawing, rectangles, ellipses and page controls. A text highlight uses one annotation per page, including selections across inline maths. In page overview, the contextual toolbar offers PDF addition, paper size and rotation of selected pages. Paper size fits all pages. Drag thumbnails to rearrange pages. Drawing and annotation tools appear in the reading view.

Save writes edits to the open file. Undo restores edits and deleted highlights or comment threads. Export comments as Markdown or JSON from the Comments heading, including authors and replies. Search previews use the same Save/Discard flow for highlights.

Signed PDFs start with an editing lock. Click it and accept the warning to edit. Blocked actions shake the lock. Supported, permitted annotation saves preserve the original signed bytes through an incremental update. Page changes and unsupported formats can affect signatures. The save checks cover content integrity and supported PDF signature permissions, not certificate trust, expiry or revocation. One temporary original is retained during the editing transaction and removed after Save or Discard. Form data must survive an annotation rewrite.

## Markdown

Read, Edit and Split share one source buffer. Split initially gives the source and preview equal space. Format supports styles, links, lists, maths, code and tables. Spreadsheet paste creates a table. Paste as Markdown preserves formatted text. Share exports PDF.

Reading previews load remote images near the viewport, with up to three requests and a 12 MiB memory cache. No disk cache is kept. Offline or unavailable images show labelled placeholders. Unsupported formulae show their original TeX while the surrounding text remains readable.

Local raster images and passive SVGs appear in previews and PDF exports. Keep assets in the document folder or its subfolders. HTML `<img>` and `<picture>` are supported. Theme variants follow the reader appearance and PDF export uses the light fallback. PDF export requires local images and supported formulae. Scripts and embedded content are excluded.

Markdown settings control line numbers, source size, spelling and live preview. TeX completion offers commands and environment blocks. Tab accepts a candidate. Escape dismisses it. See [writing assistance](../assistant.md) for proofreading and native spelling corrections.

## LaTeX

LaTeX source ZIPs can be dropped onto the Home LaTeX card or selected through it. Choose a parent folder before extraction. remile. creates a new project folder, preserves assets and leaves the ZIP unchanged. Save writes to the extracted project. Source export creates a new ZIP. Unfinished source remains editable when compilation fails.

Open a project folder, choose its main document and compile with a local TeX installation. LaTeX settings select the engine, binary directory, editor theme and history interval. Settings → LaTeX sets a shared compilation limit of 90, 180, 300 or 600 seconds. The default is 180 seconds.

Files and Outline fold independently. Drag their dividing line to resize them. Outline follows literal input, include and subfile links. Virtual collections group files without changing source paths. Cmd/Shift selects multiple files for dragging or collection moves. Removing a collection preserves its files.

Double-click a file or project title to rename it. Return or a click elsewhere confirms. Escape cancels. The + menu creates files, folders and collections. New and imported files can use any extension. File context menus offer Rename, Copy relative path, Reveal in Finder, Duplicate and Move to Trash.

The bounded title box centres names that fit and keeps the beginning of long names visible. Selecting a PDF, EPS or image asset opens a preview beside the compiled document. EPS previews and pdfLaTeX conversion require `epstopdf` and supporting tools. SyncTeX links source and PDF locations. Cmd+/ toggles comments. Tab and Shift+Tab adjust indentation.

A green check beside Compile means the PDF matches the current source. Errors opens diagnostics and dependency guidance. Settings → LaTeX → Check LaTeX Environment checks tools and declared packages without compiling or installing. Installation commands are provided for review. Successful compilation verifies the dependencies used by the project.

Compile options includes a fresh rebuild and submission comparison. The comparison builds the current source and a bibliography-embedded variant in separate snapshots. Writing tools offers reviewed bibliography embedding and author-note removal. History keeps checkpoints at the selected interval. The Recent menu can move local editing history to Trash.

## Overleaf

Home → Overleaf opens your project library. Find projects by name, account or tag. Drag to reorder them. Add projects connects an account and imports a project with a Git token.

Create a token in Overleaf → Account → Account settings → Git integration. Hover over Git token for this path. Web sign-in supports browsing, comments and project renaming. remile. reuses its own account session. It does not read another browser’s cookies. Some sign-in providers require a browser.

The connection screen checks access before reporting success. It offers recovery for expired sessions, Keychain approval, browser verification and server errors. Removing a project moves its local copy to Trash. The online project stays available.

Connected projects use the native LaTeX editor and local compiler. Local edits sync automatically. Remote changes wait for review. Online publishes saved local edits after a two-second pause while the project is open. Remote checks run every 30 seconds. New remote revisions pause publishing for review in Check changes. Resolve conflicts before updating or publishing. Offline and leaving the project stop remote work. Git access and a local TeX installation are required.

Live sync shares existing text edits in both directions while the project is open. It pauses Git publication. File changes and overlapping edits may need review. See [live synchronisation](../overleaf-realtime.md) for its current limits.

Project tags appear as muted stripes. Click to read their names. Sync ages use whole minutes. Double-clicking the title renames the online project after server confirmation. Comments opens a native view with Markdown and JSON export. Git sync does not join Overleaf’s live presence channel. Published changes appear in project history.

## Library search

Add PDF or Markdown folders to Library. Update Index scans changed files. The refresh beside a folder rereads that folder completely. Index coverage reports files without searchable text and indexing failures.

Press Return to search. Keywords use local page/passage ranking with term coverage, proximity and headings. Quoted phrases are mandatory. Boost search with Apple Intelligence optionally expands natural-language questions on this Mac. Work offline, Manual mode or an unavailable model uses standard local ranking.

Relevance groups results by document. Rank shows the global order. Results retain page context and offer PDF preview, highlights and document questions. Narrow windows use Results and Preview tabs. Returning from a document preserves results until the query, settings or index changes. Results are limited to 200 matches.

## AI and local tools

Apple Intelligence, ChatGPT and Manual share one provider selector. Ask works with PDFs, Markdown and search results. Proofreading and LaTeX suggestions present changes for review and support Undo. The eye control shows AI and CLI edits. See [AI and writing](../assistant.md) for connections, context and privacy, and [CLI](../cli.md) for local automation.

Compilation uses temporary snapshots. Replaced and failed builds are removed. Abandoned build folders are pruned after seven days or above a combined 512 MB, excluding active builds. Text history keeps up to 120 entries and 32 MB per project. Search indexes, project copies and editor drafts remain separate from these disposable caches.


The LaTeX and Overleaf build-log button stays visible in narrow windows. A dot above the terminal is red for errors or a failed build and yellow for warnings alone. Clean builds show the terminal without a dot. During compilation, the dot waits for the new result.
