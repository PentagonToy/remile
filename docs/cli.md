# CLI

Run `tools/remile help` or `/Applications/remile.app/Contents/MacOS/Remile --cli help`. Commands return JSON. `remile version` reports the same version as the application. Paths are absolute unless a command specifies a project-relative source file.

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
| `compress /path/input.pdf --output /path/new.pdf` | Compress a PDF; report original and output bytes |
| `compress /path/input.pdf --output /path/new.pdf --quality small --grayscale` | Select small, balanced or high quality and optional grayscale |
| `inspect /path/project` | List project files and main-document candidates |
| `build /path/project --output /path/new-directory --main main.tex` | Compile captured project sources |
| `build /path/project --output /path/new-directory --submission-check` | Check bibliography independence with fresh LaTeX passes |
| `comments /path/input.pdf --output /path/comments.md` | Export PDF review comments as Markdown |
| `comments /path/input.pdf --format json` | Read comments and reply relationships as JSON |
| `doctor` | Report TeX tools and configuration |

Combine accepts PDFs together or Markdown files together. Markdown output uses `.md`. Compression and PDF combination preserve their input files.

## Live editor

Live commands target the active remile. document window. Switching windows changes that target. An open request creates a window when none is open. Check `status` and the buffer fingerprint before applying edits.

| Command | Result |
| --- | --- |
| `open /path/document` | Open a document or project |
| `status` | Read document state and compile counts |
| `library-search "question or keywords" [--no-boost]` | Search the current local library with the same engine and boosting policy as the app; return ranked paths, pages, excerpts and matched terms |
| `pdf-read [/path/document.pdf] [--page N] [--find text] [--render /path/new.png]` | Read PDF page text, annotation data and search bounds; optionally render a page image |
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
| `history` | Read project checkpoints and tool markers |
| `select --file relative.tex` | Select a source file |
| `rename --file relative.tex --name NEW` | Rename a project file |
| `rename --kind project --name NEW` | Rename the project |

Markdown supports read, replace, save and export. Source replacement switches to Split and retains native Undo. Save is explicit. The eye control shows session-only CLI edit ranges in the source.

## Source tools

`transform --action strip-notes|embed-bibliography|toggle-comment|indent|outdent --file relative.tex` returns a proposal and its source fingerprint. Add `--apply --expected-sha256 HASH` to apply it. Comment and indentation actions accept UTF-16 `--start` and `--length` offsets.

Bibliography embedding prepares classic BibTeX output. Submission comparison checks current and hypothetical embedded sources in separate snapshots and returns per-result logs. The installed TeX engine performs each check. Source changes during a check appear as `sourceChanged` in the comparison response.

## Transport

The application processes fixed requests through `~/Library/Application Support/local.remile.app/Automation`. Owner-only request and response files use UUID names. The CLI writes a request, reads its response and removes both files. Edits require the current source fingerprint; exports require a new output path.

Comment exports contain the document filename rather than its local path. JSON includes a schema version, stable annotation identifiers, page, author, text, optional highlight quote, modification time and reply parent. File exports require a new `.md` or `.json` path.

For a connected Overleaf project, `comments` exports the latest snapshot from its native Comments view. Account credentials remain inside the app.

## PDF page context

`pdf-read /absolute/document.pdf --page 18 --find "Linear" --render /absolute/new.png` works without opening an editor. Page numbers start at one. The JSON response includes page count, label, bounded text, annotation types/text/rectangles and search rectangles in PDF page points with a bottom-left origin. The optional image uses a new PNG path and a maximum thumbnail dimension of 1600 points. Locked PDFs and copying restrictions are honoured.

Without a document path, `pdf-read` reads the current reader page, including unsaved annotation edits, and reports whether the document has unsaved changes. Text is capped at 64,000 characters, annotations at 500 and matches at 100 per page; the response flags truncated text. This command reads context without editing the PDF or changing its visible page.

Library search uses B0 for keywords and optionally B-guided for questions. `--no-boost`, Work offline and Manual mode keep the request on B0. The response identifies the engine and accepted expansion phrases. It does not change the search field or document selection. Start the app before issuing this live command; allow up to 60 seconds for the initial resident index and model preparation.
