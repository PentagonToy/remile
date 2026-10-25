# Workspace layout and motion

Pane defaults follow the task rather than one app-wide width. The main work area gets priority. Apple recommends reasonable minimum and maximum sizes, resizable thin dividers, persistent selection and alternatives for compact windows. These are principles, not a prescribed percentage. The defaults below are remile. product choices.

| Workspace | Navigation | Main area | Details |
| --- | --- | --- | --- |
| Home | 180 pt | Remaining window | None |
| Markdown | Outline 16%, bounded to 180–250 pt | Source and rendered preview split equally | Ask is optional |
| LaTeX and Overleaf editor | Files 18%, bounded to 180–260 pt | Source and PDF split the remaining width equally | Narrow windows choose Source or Preview |
| Overleaf library | Navigation 18%, bounded to 200–280 pt | Project library uses the remainder | None |
| Search | Results 32%, bounded to 300–460 pt | Reading preview uses the remainder | Ask is optional |
| Reference | Equal initial side panes, each 20% with a 200–320 pt bound | Wide reference list in the centre | Thumbnail and metadata inspector |

The bounds preserve readable controls at small widths and avoid oversized navigation on large displays. Reference stacks its preview below the list when three readable columns no longer fit. Enabling many reference columns adds horizontal scrolling rather than shrinking text. A person can still resize panes independently. Saved widths are clamped to the destination window when restored.

Search keeps the same PDF preview mounted when Ask opens or closes. The split reserves at least 280 pt for the PDF and 260 pt for Ask. Results yield space first in a narrow window. Opening Ask does not reload the PDF or run an AI request.

Each named split remembers its manually adjusted width. Portable settings include these widths. Reopen a workspace after importing a settings file to apply its saved split widths.

Panels and disclosures use a shared short transition. Navigation takes slightly longer. Pointer resizing stays direct. Turn off Animations in General, or use macOS Reduce Motion, to suppress added motion. Decorative clocks stop when their window loses focus or their view closes.

## Sources

- [Apple Human Interface Guidelines: Split views](https://developer.apple.com/design/human-interface-guidelines/split-views)
- [Apple Human Interface Guidelines: Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Apple Human Interface Guidelines: Layout](https://developer.apple.com/design/human-interface-guidelines/layout)

## Inline names

Existing inline file, folder, collection and project names use Return or a click elsewhere to apply. Escape cancels. The edit keeps its original target when selection changes. New file and folder drafts retain their explicit Return confirmation, and multi-field forms retain Save. Reference metadata uses the same commit and cancel rules with record revision checks.

## Opening unfinished LaTeX

The editor opens readable TeX sources independently of compilation. Main selection uses a valid saved target, root main.tex, a source containing a class declaration, then a stable source fallback. Empty documents and missing command backslashes remain editable. Projects without a readable TeX source receive a specific error. Compilation diagnostics stay inside the workspace.


## Scroll content spacing

App-owned scrolling cards reserve an 18 pt trailing gutter inside their viewport through ScrollContentSpacing. Cleanup, duplicate review, paper search, Reference settings/list/preview, Search result content, Overleaf library cards and review/combine cards use this spacing. Wider established spacing, including the User guide's 28 pt and Home's content padding, stays intact. The Reference list header reserves the same additional gutter as its rows. Native source editors and PDF canvases keep their own scrolling geometry.

Reserve the gutter around the whole card, not just its text, so both overlay and always-visible scrollbars stay separated from the card edge. Keep scrollbar tracks at the viewport edge and retain their native behaviour.


A new, empty Markdown draft closes without a save question. Entered text or whitespace still needs confirmation. Clearing a previously saved document remains an edit and keeps the save question. Explicit Save remains available for an empty draft.
