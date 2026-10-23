# Reference

Reference keeps bibliographic records and PDF attachments together. Open it from the Home sidebar. The library is on the left, references are in the middle and a small PDF preview and metadata table are on the right. Narrow windows stack the list and preview, using the same resizable sidebar as the other workspaces.

## Add and organise

Use Add to find a paper, import PDF/BibTeX files, enter details manually or paste a citation. Drop files into the list to import them. Drop PDFs onto an existing reference or its preview to attach them to that item. Bibliography-only items remain usable without a PDF. Plain citations can be organised with GPT in the entry editor before saving.

Right-click a reference to edit its details, duplicate it, regenerate its key, copy or export BibTeX, add PDFs or delete it. Command-click selects several rows and Shift-click selects a range. Right-clicking a selected row copies or exports the selected references. Delete moves the record to the app's Trash and retains its attachments. Restore is available from the Trash context menu. Empty Trash permanently removes trashed records and unshared PDFs after confirmation.

PDF imports copy the original into managed storage. The original file is not renamed or modified. PDF title and author metadata provide initial details when available. Publication years are not inferred from a file's creation date. Check imported details before citing them. Export produces BibTeX metadata, not a PDF archive.

## Citation keys

Settings below the sidebar artwork offers three fixed formats:

- `Surname_Year_FirstWord`
- `Surname_Year_FirstWord_SecondWord`
- `Surname_Year`

Keys use the first author's surname, with accents transliterated for portability. Missing authors use `Reference`, and missing years use `nd`. Collisions receive `_2`, `_3` and so on. There is no custom format field.

New records, including imported bibliographies, use the selected format. The imported source file stays unchanged and its original key is retained as provenance. Changing the setting does not rewrite stored keys. Right-click to regenerate one key, or use Key to regenerate all active records after confirming that existing document citations may need updating. Internal `crossref`, `xref`, `xdata` and `entryset` links in the same imported bibliography are remapped as records receive new keys. Key regeneration also updates such links among active records. Trash stays unchanged.

Library and Harbour have independent disclosure controls. Both start expanded and remember subsequent changes. This update opens Library once for existing installations. The large lighthouse and “Across time, a few words find you here.” appear only when both sections are collapsed. Otherwise the footer uses the compact banner. The app-wide artwork preference still applies.

## GPT review

GPT sends only the displayed citation or bibliographic entry through the existing ChatGPT connection after Suggest correction is selected. It does not upload the attached PDF. The current and suggested entries appear together, and applying is explicit. Source revisions are checked before saving so a delayed suggestion cannot overwrite a newer edit.

The prompt asks for syntax and formatting correction without inventing bibliographic facts. This does not establish external verification. Review names, dates and identifiers before applying. Plain citation input, malformed BibTeX and multiple-entry responses are bounded and validated. Your ChatGPT plan and credit settings apply. Connection and offline controls are shared with the rest of the app.

## Storage and modules

The default managed root is `~/Library/Application Support/local.remile.app/Reference`. `library.json` stores schema-versioned records with UUID identities and revisions. Attachments have separate UUIDs, content hashes and managed relative paths. A catalogue lock serialises writes across processes, atomic catalogue replacement preserves the previous committed state, and failed imports remove only their own staged files. Repeated attachment references share managed PDF bytes. Returning from the PDF reader refreshes the stored hash for every record sharing that attachment. File import parsing, PDF loading and persistence work run outside the UI actor.

The implementation separates records, citation keys, BibTeX parsing, persistence, native model/views, GPT response validation and CLI projection. It uses the existing style, split layout, sidebar artwork and ChatGPT services. Libraries keep separate metadata and citation keys while sharing identical PDFs. Cloud root selection, cloud sync, a full-text reference index and RIS import are not implemented. Online paper lookup is an explicit action, separate from local import.

## Agent access

The catalogue interface works without a document window:

```sh
remile reference libraries
remile reference list --library UUID --limit 50 --offset 0
remile reference list --query "fluid" --limit 20
remile reference list --trash
remile reference show --id UUID
remile reference export --id UUID
remile reference export --library UUID --output /absolute/new.bib
```

List returns bounded metadata with stable IDs and revisions. Show includes fields, attachment paths and BibTeX. Export omits Trash and accepts only a new `.bib` path. It uses the same repository and exporter as the native workspace. These read commands do not connect to ChatGPT or change library records. The [CLI guide](cli.md#reference-library) also documents import, metadata update, attachments, Trash/restore and key regeneration. Writes require an explicit destination or record ID, and existing-record mutations require the current revision. Native views observe catalogue changes without polling.

## Validation

`zsh tools/check_references.sh /absolute/external/check-directory` runs isolated synthetic checks for parsing, round trips, key formats/collisions, reload, optimistic revisions, recoverable deletion, attachment copying, import rollback, internal citation links, locked writers, bounded CLI reads, revision-checked CLI writes and GPT response parsing. It does not read a real library or call ChatGPT. `tools/check_cli_arguments.sh` covers the existing command argument contract separately.

## Libraries and duplicates

Right-click the left panel to add a library. Library names are entered inline in the sidebar. Right-click a library to add a collection such as KTH or Aalto. Library drag reordering is not available. Right-click a library to copy or export its active references as BibTeX, or delete it after confirmation. Library deletion moves its metadata, collections and references to Reference Trash. Restore the library from its Trash context menu. Right-click Trash and choose Empty Trash to permanently remove its metadata and unshared PDFs after a second warning. PDFs still referenced by active records remain in place. If the last active library is deleted, an empty My library is created.

Duplicate candidates have a subtle gold background. Command-click two or more candidates, then right-click Merge selected to review only that selection. The action is disabled when the selection includes unrelated records. Candidates match by PDF hash, DOI, or exact normalised title with author and year. Review duplicates recommends a base record, lets you resolve differing fields and can align metadata across libraries. Published records rank above preprints, followed by identifiers, PDF availability and completeness. This is a local recommendation, not external publication verification. Missing details are filled from the other records, matching mixed-case titles are preferred over all-capital titles and all distinct PDFs are retained. Publication-specific fields from a preprint do not overwrite a published base record. Extra entries in the same library move to Reference Trash. Entries in other libraries remain independent, and internal citation links follow changed keys. Keys may gain a suffix to avoid collisions. A local recovery snapshot is retained before merging. External manuscript citations are not rewritten.

The middle list starts with icon, title, author, Journal / Publisher and year. The venue column uses the journal, then conference or book title, then publisher. Settings can show or hide author, year, publisher, Journal / Publisher, citation key, type and date added. Title stays visible. Manual entry offers six common types and a manual BibTeX type under Other. Imported uncommon types and extra fields remain intact. The preview has page arrows and opens the existing PDF reader. Returning restores the selected library, reference and thumbnail page. The unstriped metadata table shows stored publication details, identifiers, keywords, notes and added/modified times. Imported unknown fields remain visible. Abstracts stay stored but are hidden from this view. BibTeX copies and exports omit abstracts by default, with an Include abstract in BibTeX setting to opt in. The Home sidebar starts at 180 points and remains resizable.

CLI export without a reference or library ID uses the first library in saved order. List can return all libraries, with library IDs on every record. Use an explicit library ID for repeatable exports.

## Collections and portable preferences

A library has one optional collection level. Collection entries share their parent library’s citation key namespace so exporting a whole library cannot create colliding keys merely because entries are in different collections. Move to collection changes the existing record’s location without copying its metadata or key. Add to library creates an independent record in another library and shares identical PDF bytes. Parent library views and exports include active collections. Deleting a collection does not delete its parent or other collections.

General Settings offers Export settings and Import settings. A versioned JSON file carries appearance, editing, search, Reference column/key/export preferences and named pane widths. It can be placed in iCloud Drive or Dropbox and imported on another Mac. Import is reviewed before applying. Account connections, credentials, network permissions, document paths and library data are excluded. This is manual transfer, not automatic cloud synchronisation. See [workspace layout](workspace-layout.md) for defaults and motion.

Metadata values can be edited in place with a double-click or the accessibility Edit value action. Return or a click elsewhere saves. Escape cancels without a later focus change applying the draft. Saving keeps the newly clicked reference selected and waits for an operation already in progress. The editor keeps the record revision captured when editing starts, so a stale edit cannot overwrite a later change. Empty titles and invalid BibTeX values are rejected. Citation keys and added/modified times use their dedicated actions and remain read-only in this inspector.

## Import review and readable metadata

BibTeX source keys are case-sensitive. Imports retain each original key and assign distinct managed keys, including numbered collisions. Internal citation links are remapped with exact source-key matching. The supplied 63-entry bibliography passed whole-batch import and field-preserving export checks. Malformed syntax still fails the transaction rather than importing an incomplete bibliography.

The list and metadata inspector render protected braces, common TeX formatting, accents and symbols as readable labels. The author column uses the first family name and et al. for multiple authors. The inspector keeps full author names, including braced organisations. These labels do not rewrite the source fields. Editing opens the original stored value and BibTeX export preserves its protection and commands.

Clean up separates Metadata suggestions from Duplicates in two tabs, each showing its count. It opens local suggestions for the current library. Users choose proposed formatting and missing PDF metadata changes before applying. Citation keys, notes and abstracts stay unchanged. Duplicate groups open a separate merge review. Applying a batch checks every captured revision in one transaction. A stale proposal applies nothing. Formatting proposals cover whitespace and DOI wrappers, with no automatic title case conversion or invented publication facts.

PDF imports read embedded titles and authors, one unambiguous first-page DOI and, when embedded titles are generic, a bounded prominent-text title candidate. A filename remains the fallback. Local cleanup can propose missing fields from existing attachments. These are fallible extraction results, not external bibliographic verification. Local extraction does not use OCR, a DOI service or automatic GPT upload. Find a paper provides a separate online lookup. Publication years are not guessed from file or PDF creation dates. Parser, PDF extraction, cleanup proposals and display rendering have separate modules behind the repository service.


## Find a paper

Choose Add → Find a paper and enter a DOI or title. Crossref provides up to five metadata results. Selecting a result asks OpenAlex for public PDF locations, preferring published versions. Where an open landing page has a standard citation PDF link, a bounded page-head lookup can discover it. Include PDF is available when a candidate is found. Add saves the selected metadata and optional PDF together. No account, email or API key is added by this flow.

Search sends the entered query to Crossref, then the selected DOI to OpenAlex. Public landing pages and PDF hosts are contacted only for that selection. The app-wide offline control applies. There is no periodic background search or automatic PDF upload to GPT. Requests use an ephemeral session without stored credentials or cookies, public HTTPS destinations, time limits and response-size limits. Downloads are limited to 25 MB and must be readable, unlocked PDFs. This is a public-document route, not authenticated publisher access.

A missing or blocked PDF does not prevent metadata-only import. If a download fails, clear Include PDF and add the metadata. Crossref coverage, public links and server access vary. DOI results and downloaded documents should be checked before use. Search does not automatically add papers or merge possible duplicates.


## PDF drops and attachment markers

Harbour occupies a separate section between the Library divider and the sidebar banner divider. Its square drop surface has 20 pt breathing room above and below. Library uses the remaining height above that section and scrolls independently as it grows. Select a library or collection, then drop PDFs or BibTeX into Harbour. Image-file import is not supported. Drop directly onto a reference row or its preview to attach to that specific record. When a file enters the Reference workspace, the content darkens slightly and Harbour glows. Other rows become quieter and the hovered row gains a gold outline. The interaction uses the shared motion preferences. Rows with an attached PDF show a small gold dot on their type icon, with an accessible PDF attached label.

Untargeted PDF drops into Harbour or the reference list extract local metadata first. A single active record in the selected root library with the same normalised DOI or identical PDF hash receives the attachment. Existing fields and citation keys stay intact, while missing fields may be filled. If several records match, a new record remains available for reviewed cleanup. Other libraries keep separate records and can share identical PDF bytes. Dropping onto a row remains an explicit attachment choice regardless of extracted metadata. File-picker imports keep their existing separate-record behaviour. No external metadata request is triggered by a drop.

The drop captures the selected library before asynchronous file-provider loading, so changing selection during loading does not redirect the files. Managed imports remain atomic and retain the original files. Attachment errors do not silently convert a targeted drop into a library import.


Citation key appears first in the metadata inspector. Copies remain in the context menu rather than adding a button below the table. Right-click a reference row or metadata inspector to remove attachments. A single attachment is unlinked directly. With several attachments, select files in the Attachments sheet and use its trash action. Metadata and citation keys remain unchanged. Original files and PDFs used by other records are retained. Unlinked managed bytes wait for an explicit Empty Trash action before collection, including when no records are in Trash. Removing a stale attachment selection applies nothing.

## Cite while writing

The book button in LaTeX, Overleaf, Markdown and Search opens the same local reference picker. Choose a library or collection and find a reference. Copy citation returns `\cite{key}` for LaTeX or `[@key]` for Markdown. Markdown citation rendering depends on the export tool.

Insert citation in a TeX source also adds its BibTeX entry to the project's existing bibliography. One editable `.bib` is selected automatically. With several, choose the destination. A project without a bibliography gets `remile-references.bib`, which you must connect through your usual BibTeX or biblatex setup. Existing entries and bibliography configuration stay unchanged. Identical entries are reused. A conflicting key stops insertion. Removing a citation never removes its bibliography entry. Source insertion supports ordinary Undo.

The picker reads the catalogue when opened. It does not run a background synchronisation service. Connected Overleaf projects use their existing save and sync behaviour.

### Citation completion

In a TeX source, type `\cite{k` to search citation keys, titles, authors and years. Rows show citation keys. The selected entry’s title, authors, year and Project or Library origin appear below the list. Project bibliography entries appear first, followed by entries from the library chosen with the book button. Arrow keys move through suggestions, Return or Tab inserts, and Escape dismisses. Common natbib and biblatex citation commands, optional arguments and comma-separated citation lists are supported.

Choosing a Library entry adds it to the selected bibliography before inserting its key. Existing keys are never overwritten. If several bibliographies exist, choose one with the book button first. The library and destination are remembered separately for each project on this Mac. No preference file is added to the manuscript. The catalogue is loaded lazily for the writing session and refreshed when the reference picker is opened. Bibliography buffers are reparsed only when they change. Automatic completion currently applies to TeX sources, not Markdown citation syntax.

### Follow a citation to its source

In a TeX source, right-click a citation key and choose **View reference source**. The source sheet keeps your manuscript open at the same position. You can also use **View source** in the shared reference picker or a Reference row’s context menu. Project bibliography metadata is shown even when no local PDF is available. A managed PDF is linked only when the reference metadata matches. A matching key alone never attaches a different paper.

Choose an attachment to read its verified local PDF. The source viewer is read-only. **Ask about source** uses the existing AI provider and conversation controls. With no PDF selected, Ask receives bibliographic metadata only, explicitly labelled as such. With a PDF selected, submitting a question retrieves passages from that PDF. Opening the sheet or preview does not submit an AI request. Conversations are kept separately for each reference attachment. PDF page numbers are positions in the PDF, not necessarily printed page labels.


### Keep a source passage

Select text on one page in the reference source viewer, then choose **Save selected passage**. Saved passages keep the reference ID, attachment ID, PDF hash, page position, UTF-16 text range and extracted text. Select a saved passage to return to that PDF and highlight its text. **Copy citation** uses the workspace’s LaTeX or Markdown syntax. Saving a passage does not insert text, change a bibliography or assess whether the source supports a claim.

Passages are stored locally outside the manuscript and loaded only when requested. Each reference holds up to 200 passages of 4,000 UTF-16 units each. Repeated saves of the same range reuse the existing passage. A changed or missing attachment cannot be used as verified evidence. Trashing a reference hides its passages, restoring it makes them available again, and Empty Trash removes passages belonging to permanently removed references. Ask can use the current PDF selection when you submit a question. No background audit or AI request runs when you save a passage.
