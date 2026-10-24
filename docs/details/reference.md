# Reference

Reference keeps citations and PDFs together. Open it from Home. Libraries and collections sit on the left, records in the middle, and metadata and a PDF preview on the right.

## Add and organise

Use Add to import PDF or BibTeX files, enter details or find a paper. Drop files into Harbour to import them into the selected library. Drop a PDF on a record or its preview to attach it to that record. Imports copy PDFs into managed storage and retain the originals.

PDF metadata and first-page text provide initial bibliographic details without AI. Read metadata in a row's context menu reviews local corrections. Look up can retrieve official DOI or arXiv metadata. It does not upload the PDF. Review proposals before applying them. Unknown fields remain unknown, and scanned PDFs may require manual details.

Find a paper starts from a record's DOI or title. It checks matching PDFs open in remile, managed attachments and public Crossref/OpenAlex results. Review the result before choosing Attach PDF. Add local PDF remains available when no public copy is found. The existing record and citation key are retained.

Right-click the sidebar to create a library or a collection. A collection belongs to one parent library. Move to collection keeps the record's identity. Add to library creates independent metadata while sharing identical PDF bytes.

Command-click selects several rows and Shift-click selects a range. Row context menus offer editing, BibTeX copying/export, attachments and Trash. Delete retains the record and attachments in Trash. Restore returns them. Empty Trash permanently removes discarded records and unshared files after confirmation.

## Columns and keys

Title, Author, Journal / Publisher, Year and Type are visible by default. Click a heading to sort ascending, then again to reverse. Text uses natural alphabetical order and years use numeric order. Empty values stay last. Drag a heading's right edge to resize it. Widths and visible columns are remembered and included in presets. Title stays visible and starts widest.

Settings below the sidebar artwork controls columns, citation keys and abstract export. Keys use the first author's surname, year and one or two title words. Missing authors use `Reference`, missing years use `nd`, and collisions receive numeric suffixes. Changing the rule affects new records. Regenerating stored keys can require changes to manuscript citations.

Double-click a metadata value to edit it. Return saves and Escape cancels. BibTeX exports omit abstracts unless enabled in Reference settings. Uncommon imported types and fields remain stored.

## Review and Undo

Clean up reviews local metadata proposals and duplicate candidates. Merge selected is available for related records. Review the base record and conflicting fields before merging. Distinct PDFs are retained and extra records move to Trash. Manuscript citations are not rewritten.

Undo and Redo retain up to 30 session changes within an 8 MB metadata limit. PDF bytes are not copied into Undo. External catalogue changes clear incompatible history. Empty Trash clears Undo.

GPT review is optional and separate from local extraction and public metadata lookup. Suggest correction sends the displayed citation through the configured ChatGPT connection, without its PDF. Applying a suggestion requires review and a current source revision. Your ChatGPT plan and credit settings apply.

## Storage and other Macs

Settings → Storage shows the active library folder. The default is `~/Library/Application Support/local.remile.app/Reference`, outside the application. macOS keeps preferences in `~/Library/Preferences/local.remile.app.plist`. Locations reveals full file details and Finder actions.

Choose Change → Move library to copy the catalogue, attachments and saved passages into a new `remile-reference` folder. Choose a parent in Dropbox or iCloud Drive to let that service synchronise the folder. remile verifies copied bytes and keeps the previous folder as a recovery copy. Close Reference PDFs before switching locations.

On another Mac, let the complete folder download, then choose Change → Open library and select that Mac's synced `remile-reference` folder. Opening validates the catalogue without importing, merging or duplicating records. PDFs use relative attachment paths, so different usernames and cloud folder locations do not change their identities. A missing catalogue produces an error rather than an empty replacement library.

An opened library starts read only. Catalogue changes, passage saves and saving over managed PDFs are blocked. Copies can be saved outside the library. To edit, turn off Read only on one Mac after folder sync finishes. Wait for changes to finish syncing before editing on another Mac. The local file lock does not coordinate writers on different computers, and remile does not merge cloud conflicts automatically. Keep unresolved conflict files until they have been reviewed.

Keep the library downloaded on every Mac that needs offline access. Apple documents [Keep Downloaded](https://support.apple.com/en-gb/guide/mac-help/mchl1a02d711/mac). Dropbox describes [conflicted copies](https://help.dropbox.com/organize/conflicted-copy) caused by concurrent or offline edits. Shared-folder behaviour is tested with local copies at different paths. Two physical Macs and provider conflict recovery require separate validation.

## Presets

Settings → Storage → Presets offers Save preset and Load preset. A versioned JSON file carries appearance, editor, search, citation-key, column and pane-width preferences. Save separate files for different working environments, or put a preset in Dropbox or iCloud Drive and load it on another Mac. Existing remile settings JSON exports remain compatible.

Loading requires confirmation. Accounts, credentials, network permissions, documents, library paths and read-only access mode stay local. A preset restores the supported preferences it contains. It does not synchronise itself automatically or transfer library data. Reopen a workspace to apply saved pane widths.

## Cite while writing

The book button in LaTeX, Overleaf, Markdown and Search opens the reference picker. Copy citation returns `\cite{key}` for TeX or `[@key]` for Markdown. Markdown rendering depends on the export tool.

In TeX, type `\cite{` to search keys, titles, authors, years and stored abstracts. Project bibliography entries appear before library entries. Arrow keys select a suggestion, Return or Tab inserts the key, and Escape dismisses. No AI request or PDF analysis runs while typing.

Inserting a library citation adds its BibTeX entry to the chosen project bibliography. Choose a destination if several bibliographies exist. A project without one receives `remile-references.bib`, which must be connected through its bibliography configuration. Existing entries are reused. Conflicting keys stop insertion. Removing a citation does not remove its bibliography entry.

Right-click a citation and choose View reference source to inspect metadata and a matching managed PDF. A matching key alone never attaches a different paper. Ask about source sends a question only when submitted. Without a selected PDF, it receives bibliographic metadata only.

Select text on a PDF page and choose Save selected passage to retain its reference ID, PDF hash, page, text range and extracted text. Selecting the passage returns to its source. A missing or changed attachment cannot serve as verified evidence. Saving does not insert manuscript text or assess whether it supports a claim.

In Search, Save reference beside Open collects the PDF into a selected Reference library. The original file and search position are retained. A unique matching record is reused. Resolve ambiguous duplicates before collecting again.

## CLI

The [CLI](../cli.md#reference-library) shares the native catalogue and access checks. Commands work without a document window:

```sh
remile reference storage
remile reference libraries
remile reference list --query fluid --sort year --order desc --limit 20
remile reference show --id UUID
remile reference export --library UUID --output /absolute/new.bib
```

Reads return stable record IDs and revisions. Existing-record writes require the expected revision. Exports require a new output file. Native views observe catalogue changes through directory events. Search indexes, accounts and device caches stay local.
