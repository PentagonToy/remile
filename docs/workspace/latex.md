# LaTeX

Stay close to the source, with the finished page beside it.

## Open and compile

1. Choose LaTeX from Home and open a project folder or source ZIP.
2. Choose the main document if asked.
3. Select Compile to build the PDF with your local TeX installation.

A source ZIP opens into a new project folder. The ZIP stays unchanged. Source remains editable if compilation fails.

## Find your way

Files holds the project. Outline follows its sections. Drag the divider to give either the source or PDF more room.

Double-click in the PDF to return to the corresponding source. Type `\cite{` to search your bibliography and [Reference](../reference.md) while writing.

## When a build needs attention

Open Errors beside Compile. Start with the highest-priority issue and follow its source link. A green check means the PDF matches the current source.

Use **Settings → LaTeX → Check LaTeX Environment** to inspect the local tools. remile provides guidance before any package installation.

## Buttons at a glance

| Button | What it does |
| --- | --- |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/sidebar.svg" alt="" width="24" height="24"> **Files and outline** | Show the project navigation. |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/review.svg" alt="" width="24" height="24"> **Review** | Ask source-linked questions about the manuscript. |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/sparkles.svg" alt="" width="24" height="24"> **Editor tools** | Review source transformations before applying them. |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/eye.svg" alt="" width="24" height="24"> **Review edits** | Show or hide AI and CLI edits. |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/history.svg" alt="" width="24" height="24"> **History** | Compare saved local source versions. |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/terminal.svg" alt="" width="24" height="24"> **Build logs** | Read compiler output, errors and warnings. |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/pdf.svg" alt="" width="24" height="24"> **Show PDF** | Return to the last successful PDF. |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/books.svg" alt="" width="24" height="24"> **Reference** | Choose citations and their bibliography destination. |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/export.svg" alt="" width="24" height="24"> **Export** | Export the PDF or project sources. |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/play.svg" alt="" width="24" height="24"> **Compile** | Build the PDF. The adjacent menu holds build options. |

[Shared buttons and status marks](../buttons.md)

## Read the build status

| Mark | Meaning |
| --- | --- |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/terminal-error.svg" alt="" width="24" height="24"> **Terminal · red dot** | Errors, a failed build or a setup issue. Open Build logs and start with the first-priority issue. |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/terminal-warning.svg" alt="" width="24" height="24"> **Terminal · yellow dot** | Warnings without errors. Open the log to review them. |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/terminal.svg" alt="" width="24" height="24"> **Terminal · no dot** | No error or warning mark for the last result. This alone does not mean the PDF is current. |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/check.svg" alt="" width="24" height="24"> **Green check** | The PDF matches the current source. |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/stale.svg" alt="" width="24" height="24"> **Dashed circle** | Source changed since the PDF was built. Compile to update it. |

During compilation, the terminal dot waits for the new result. Your source stays editable when a build fails.

[Compiler, files and history details](../details/features.md#latex) · [Review a manuscript](../manuscript-review.md) · [LaTeX assistance](../details/assistant.md#writing)
