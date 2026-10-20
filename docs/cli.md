# CLI

Run `tools/remile help` or `/Applications/remile.app/Contents/MacOS/Remile --cli help`. Commands return JSON. Paths are absolute unless a command specifies a project-relative source file.

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
| `doctor` | Report TeX tools and configuration |

Combine accepts PDFs together or Markdown files together. Markdown output uses `.md`. Compression and PDF combination preserve their input files.

## Live editor

| Command | Result |
| --- | --- |
| `open /path/document` | Open a document or project |
| `status` | Read document state and compile counts |
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
