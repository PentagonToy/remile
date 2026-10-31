# LaTeX

Stay close to the source, with the finished page beside it.

## Open and compile

1. Choose **LaTeX** from Home to open an untitled draft. To open an existing project, drop its folder or source ZIP onto the LaTeX button.
2. Choose the main document if asked.
3. The first compile starts automatically with your local TeX installation. Choose Compile or press `⌘Return` after later edits.

Save chooses a folder for a new draft. An unchanged draft closes quietly. Edited drafts ask whether to save, discard or stay. Working copies remain in remile’s private draft folder until saved or discarded.

A source ZIP opens into a new project folder. The ZIP stays unchanged. Source remains editable if compilation fails.

## Find your way

Files holds the project. Outline follows its sections. Drag the divider to give either the source or PDF more room.

Opened files appear in the bottom tab bar. Select a tab to switch source, drag it to change its order, or use + to open another project file. Double-click a tab to rename its file. Closing a tab keeps your edits and the file in the project. At least one file stays open. Source tabs stay within their window.

Use **Control-Tab** and **Control-Shift-Tab** to move between source tabs. **Command-W** closes the current tab. When only one source tab remains, it closes the project through the usual save confirmation.

Source line numbers are on by default. Change **Settings → LaTeX → Line numbers** to hide them. The same setting applies to Overleaf sources.

Double-click in the PDF to return to the corresponding source. Word context refines the target when it matches clearly. Ambiguous text and figures keep the SyncTeX location. Selecting text alone does not move the source. Type `\cite{` to search your bibliography and Reference while writing. [Read the citation hints →](../reference.md#read-citation-hints)

Inside `\includegraphics{…}`, type part of a filename to see matching project images. `\input{…}` and `\include{…}` suggest TeX files. `\ref{…}` and `\eqref{…}` suggest labels from the project. Completing a supported `\begin{…}` inserts its matching end and places the cursor inside. These suggestions use local project data without a network request.

## Find and complete

Press `⌘F` to open Find below the source. `⌥⌘F` also opens the replacement row. `⌘G` moves to the next match and `⇧⌘G` to the previous one. Match case, whole words and regular expressions are available beside the query or in Search options when the pane is narrow. Escape closes Find. Replace and Replace All are undoable. In regular expressions, `$1`, `$2` and later groups refer to captured text.

Type a backslash and at least two letters for local command suggestions. `⌥Escape` explicitly opens completion for a shorter prefix. Arrow keys choose an item, Return or Tab accepts it, and Escape dismisses the list. Ordinary prose does not open command suggestions.

Completion includes common maths and document commands, package and class names, project files, bibliography filenames, labels and commands defined with `\newcommand` or `\DeclareMathOperator`. Project-defined environments receive a matching end. Package suggestions name common choices. They do not verify installation or install anything.

Suggestions use a bounded, lazy project index off the UI thread. Very large files or projects may have definitions outside that index. The source remains editable and compilation still uses the complete project.

## Ask about your manuscript

Open the speech bubble for source-linked questions using your selected assistant. Choose **Review manuscript** above the message field to use your saved review criteria. This works without an Overleaf account.

## When a build needs attention

Open Errors beside Compile. Start with the highest-priority issue and follow its source link. A green check means the PDF matches the current source.

Use **Settings → LaTeX → Check LaTeX Environment** to inspect the local tools. remile provides guidance before any package installation.

Click the source background control beside the text size to switch between **Default** and **Paper**. Default follows the app appearance. Paper stays softly white.

The terminal and PDF share one button. Open logs, then click the PDF icon to return to the previous preview position.

## Buttons at a glance

| Button | What it does |
| --- | --- |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/sidebar.svg" alt="" width="24" height="24"> **Files and outline** | Show the project navigation. |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/chat.svg" alt="" width="24" height="24"> **Ask** | Ask about the source or open manuscript review. |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/sparkles.svg" alt="" width="24" height="24"> **Editor tools** | Review source transformations before applying them. |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/eye.svg" alt="" width="24" height="24"> **Review edits** | Show or hide AI and CLI edits. |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/history.svg" alt="" width="24" height="24"> **History** | Compare saved local source versions. |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/terminal.svg" alt="" width="24" height="24"> **Build logs / PDF** | Open compiler output; click again to return to the previous PDF position. |
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
