# CLI

Run `tools/remile help` or `/Applications/remile.app/Contents/MacOS/Remile --cli help`. Commands return JSON. `remile version` reports the same version as the application. Paths are absolute unless a command specifies a project-relative source file.

Put an input path before options and quote paths or values containing spaces. Unknown, repeated and incomplete options fail before dispatch. Numeric options must be valid integers. Source offsets are non-negative UTF-16 values, and `--length` requires `--start`. The expected SHA-256 must match the lowercase hash returned by `read`.

## Install the command

The application includes `Contents/Resources/CLI/remile`. For a local DMG installation in `/Applications`, add a symlink in a directory on your PATH:

```sh
mkdir -p "$HOME/.local/bin"
ln -s /Applications/remile.app/Contents/Resources/CLI/remile "$HOME/.local/bin/remile"
remile version
remile status
```

Keep an existing command if that name is already in use. Homebrew manages its CLI link through the cask. The bundled launcher resolves the installed app location and calls the same native CLI used by `tools/remile`.

## Document tools

These commands run independently of the application window. Output paths identify new files.

| Command | Result |
| --- | --- |
| `combine /path/one.pdf /path/two.pdf --output /path/new.pdf` | Combine PDFs in argument order |
| `combine /path/one.md /path/two.md --output /path/new.md` | Append Markdown sources in argument order |
| `compress /path/input.pdf --output /path/new.pdf` | Compress a PDF. Report original and output bytes |
| `compress /path/input.pdf --output /path/new.pdf --quality small --grayscale` | Select small, balanced or high quality and optional grayscale |
| `inspect /path/project` | List project files and main-document candidates |
| `build /path/project --output /path/new-directory --main main.tex` | Compile captured project sources |
| `build /path/project --output /path/new-directory --submission-check` | Check bibliography independence with fresh LaTeX passes |
| `comments /path/input.pdf --output /path/comments.md` | Export PDF review comments as Markdown |
| `comments /path/input.pdf --format json` | Read comments and reply relationships as JSON |
| `doctor` | Report TeX tools and configuration |

Combine accepts PDFs together or Markdown files together. Markdown output uses `.md`. Compression and PDF combination preserve their input files.

## Reference library

`reference libraries` lists stable library/collection identities and parent IDs. `reference list [--library UUID] [--query text] [--limit 1..200] [--offset N] [--trash]` returns bounded bibliographic metadata with stable record IDs and revisions. `reference show --id UUID` returns fields, attachment paths and BibTeX. `reference export [--library UUID] [--id UUID] [--output /absolute/new.bib]` returns or exports active records. The output file must be new. These commands use the shared local catalogue without a running editor or model request. See [Reference](reference.md) for the native workspace and fixed citation-key formats.

Reference writes use the same transaction service as the native workspace:

| Command | Result |
| --- | --- |
| `reference import --library UUID --source-file /path/records.bib` | Import BibTeX or a PDF into an explicit library or collection |
| `reference update --id UUID --expected-revision UUID --source-file /path/record.bib` | Replace metadata from one BibTeX entry, preserving the citation key and an omitted abstract |
| `reference attach --id UUID --expected-revision UUID --source-file /path/paper.pdf` | Attach a managed PDF |
| `reference detach --id UUID --expected-revision UUID --attachment UUID` | Remove an attachment link. Shared bytes remain until unused-file cleanup |
| `reference trash --id UUID --expected-revision UUID` | Move the record to Reference Trash |
| `reference restore --id UUID --expected-revision UUID` | Restore the record |
| `reference regenerate-key --id UUID --expected-revision UUID` | Apply the current citation-key rule |

Read `show` immediately before a mutation and supply its revision. A stale revision fails without applying the change. The native workspace reloads external catalogue changes through directory events. Permanent deletion, library creation, merge and network lookup remain native actions. If a write is interrupted, inspect the catalogue before retrying. Import is not idempotent.

## Live editor

Run `documents` to discover open document sessions, then pass `--target UUID` to a live document command. `status` also returns this identity. An explicit target never falls back to another window, and reopening a document gives it a new session identity. Without a target, commands retain active-window behaviour. Check the target status and buffer fingerprint before applying edits. An open request creates a window when none is open.

| Command | Result |
| --- | --- |
| `open /path/document` | Open a document or project |
| `documents` | List open document session identities, paths, kinds and unsaved state |
| `status [--target UUID]` | Read document state and compile counts |
| `diagnostics` | Read main-process memory, source size, cached hashes, build-cache ownership and automation transport |
| `library-search "question or keywords" [--no-boost]` | Search the current local library with the same engine and boosting policy as the app. Return ranked paths, pages, excerpts and matched terms |
| `pdf-read [/path/document.pdf] [--page N] [--find text] [--render /path/new.png]` | Read PDF page text, annotation data and search bounds. Optionally render a page image |
| `read [--file relative.tex]` | Read the buffer, SHA-256 and CLI edit ranges |
| `replace --source-file /path/source --expected-sha256 HASH [--file relative.tex]` | Apply an undoable buffer edit |
| `save` | Save the current document or project |
| `export --kind pdf --output /path/new.pdf` | Export PDF |
| `export --kind source --output /path/new.md` | Export the Markdown buffer |
| `export --kind source --output /path/new.zip` | Export a LaTeX project snapshot |
| `logs [--tail characters]` | Read compiler output and structured diagnostics |
| `compile [--scratch] [--submission-check]` | Compile or check the current source |
| `submission-compare` | Start current/embedded submission checks |
| `submission-compare --status` | Read both results, progress, logs and captured source hashes |
| `comments [--format markdown\|json] [--output /path/comments.json]` | Read or export current PDF comments, including unsaved notes |
| `review [--run\|--stop\|--clear] [--file relative.tex]` | Start a manuscript review, read saved questions, stop pending work or clear results |
| `review --criteria` | Read the bundled review criteria and question instructions |
| `review [/path/project] [--format markdown\|json] [--output /path/new-questions.md]` | Read or export saved manuscript questions and source evidence |
| `history` | Read project checkpoints and tool markers |
| `select --file relative.tex` | Select a source file |
| `rename --file relative.tex --name NEW` | Rename a project file |
| `rename --kind project --name NEW` | Rename the project |

Markdown supports read, replace, save and export. Source replacement switches to Split and retains native Undo. Save is explicit. The eye control shows session-only CLI edit ranges in the source.

[Manuscript review](manuscript-review.md) returns questions linked to captured source versions. Starting, stopping and clearing require the running app. Starting also requires the target LaTeX project to be open. `--run` returns immediately, so read `review` again for progress and results. An explicit project directory supports offline reading and export of saved results.

## Source tools

`transform --action strip-notes|embed-bibliography|toggle-comment|indent|outdent --file relative.tex` returns a proposal and its source fingerprint. Add `--apply --expected-sha256 HASH` to apply it. Comment and indentation actions accept UTF-16 `--start` and `--length` offsets.

Bibliography embedding prepares classic BibTeX output. Submission comparison checks current and hypothetical embedded sources in separate snapshots and returns per-result logs. The installed TeX engine performs each check. Source changes during a check appear as `sourceChanged` in the comparison response.

## Transport

The application processes fixed requests through `~/Library/Application Support/local.remile.app/Automation`. Directory events wake the server when files change. It does not poll while idle. Owner-only request and response files use UUID names. The CLI writes a request, reads its response and removes both files. Edits require the current source fingerprint. Exports require a new output path.

A timeout does not confirm whether an operation ran. Inspect the current state before retrying a write. Operation expiry and recovery remain planned in the [agent and library strategy](agent-library-strategy.md). Use an explicit session target for document edits. Offline path commands and global library search do not use session targets. For PDF reads, comments and reviews, choose a path or a target rather than combining them.

`diagnostics` reads the active workspace without editing it or generating AI requests. Memory values describe the main process and exclude WebKit helper processes and system model services. Active build folders are ownership counts, not an on-disk size measurement. Use matched documents and window states when comparing runs.

Comment exports contain the document filename rather than its local path. JSON includes a schema version, stable annotation identifiers, page, author, text, optional highlight quote, modification time and reply parent. File exports require a new `.md` or `.json` path.

For a connected Overleaf project, `comments` exports the latest snapshot from its native Comments view. Account credentials remain inside the app.

## PDF page context

`pdf-read /absolute/document.pdf --page 18 --find "Linear" --render /absolute/new.png` works without opening an editor. Page numbers start at one. The JSON response includes page count, label, bounded text, annotation types/text/rectangles and search rectangles in PDF page points with a bottom-left origin. The optional image uses a new PNG path and a maximum thumbnail dimension of 1600 points. Locked PDFs and copying restrictions are honoured.

Without a document path, `pdf-read` reads the current reader page, including unsaved annotation edits, and reports whether the document has unsaved changes. Text is capped at 64,000 characters, annotations at 500 and matches at 100 per page. The response flags truncated text. This command reads context without editing the PDF or changing its visible page.

Library search uses B0 for keywords and optionally B-guided for questions. `--no-boost`, Work offline and Manual mode keep the request on B0. The response identifies the engine and accepted expansion phrases. It does not change the search field or document selection. Start the app before issuing this live command. Allow up to 60 seconds for the initial resident index and model preparation.


Reference list summaries include publication/type and a summaryTruncated flag. Title is limited to 1,000 characters, authors/publication to 500 and year to 32. Use show with an explicit ID for the complete stored fields. Each response reads records and library identities from one catalogue snapshot.

`REMILE_CHECK_PYTHON=/path/to/python3.12 zsh tools/check_automation_targets.sh /absolute/external/check-directory` runs isolated ZIP and multi-document targeting checks. Fixtures cover retained assets, unsafe paths, existing destinations, nested Finder archives and unfinished LaTeX source. No user document or account is used.

### Citation payloads

`remile reference citation --id UUID --kind latex` returns a citation, BibTeX entry and reference revision without changing files. Use `--kind markdown` for `[@key]` syntax. Discover IDs through `reference list`. An agent can inspect the destination bibliography with `read`, then use the existing hash-checked `replace` workflow to append the entry. Check existing keys before writing and preserve the original source. No citation command deletes entries or automatically changes bibliography configuration.

`remile reference suggest --library UUID --query text --limit 8` returns local library suggestions using the same citation matcher as the editor. Query matches citation keys, titles and authors. Pass a returned ID to `reference citation` for the citation and BibTeX payload. This read-only command uses the explicitly chosen library, not an active editor window or its project bibliography.

### Read a reference source

Use `reference show --id UUID` to discover attachment IDs. Then run `remile reference evidence --id UUID --attachment UUID --page 1` to read one verified PDF page. The response includes the reference revision, attachment ID, SHA-256, PDF page position and bounded extracted text. Missing, changed or restricted files fail explicitly. This command is read-only and makes no AI request. Agents can pass the returned evidence to their own reasoning workflow. The in-app Ask panel uses the same attachment identity checks before retrieving source passages.


### Save and read source passages

`remile reference passages --id UUID` returns saved passages, their provenance and whether each original attachment is still listed with the same hash. This flag checks catalogue metadata, not the current file bytes. Read `reference evidence` to verify the PDF bytes before using its text.

`remile reference save-passage --id UUID --attachment UUID --expected-sha256 HASH --page 1 --start 0 --length 120` saves text extracted from that verified PDF range. The hash comes from `reference show` or `reference evidence`. Start and length are UTF-16 offsets in the full PDF page text. The command rejects an outdated hash, invalid range, copying restrictions and selections over 4,000 units. It never accepts replacement quote text. The native viewer uses the same writer. The result includes a stable passage ID and can be exported by saving the JSON response. Repeated saves of the same PDF range reuse that ID. These commands make no AI request or manuscript edit.


`diagnostics` includes decorative update ticks and whether the app has an active key window. Compare tick differences over a measured interval. Paused or hidden artwork should add no ticks. These fields describe presentation activity, not GPU usage or a whole-app performance score.
