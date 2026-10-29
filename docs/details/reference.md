# Reference

Reference keeps citations and PDFs together. Open it from Home. Libraries and collections sit on the left, records in the middle, and metadata and a PDF preview on the right.

## Add and organise

Use Add to import PDF or BibTeX files, enter details or find a paper. Drop files into Harbour to import them into the selected library. Drop a PDF on a record or its preview to attach it to that record. Imports copy PDFs into managed storage and retain the originals.

PDF metadata and first-page text provide initial details without AI. The PDF appears before background lookup finishes. Cancelling lookup or a failed request keeps the saved PDF and local record.

### Metadata lookup

| Action | Source | How changes are applied |
| --- | --- | --- |
| **Automatic PDF import lookup** | A detected DOI or arXiv ID, while online and authors or year are missing. | Fill empty fields. Keep the saved PDF, citation key and existing values. |
| **Look up metadata** | A DOI, arXiv ID or one exact title candidate. No PDF is required. | Fill empty fields even when authors and year already exist. Keep existing values. |
| **Read metadata…** | Metadata and text from the attached PDF. | Review proposed corrections before applying them. |

Manual lookup remains available for a usable identifier or a full title. Work offline, an ongoing catalogue operation, or insufficient identifying information can disable it. A disabled action does not mean the metadata is complete. A successful lookup may find nothing additional to fill.

Title lookup sends the title to the bibliographic service. Automatic lookup sends identifiers. Neither uploads the PDF. Ambiguous title matches ask for a DOI or arXiv ID. Unknown fields remain unknown, and scanned PDFs may need manual details.

Lookups follow Work offline, cancel active requests and reuse results within a batch. arXiv uses the original submission date for the preprint year and retains the requested version ID. Published journal or conference details are not replaced with a preprint's publication fields.

Crossref and arXiv abstracts are saved with the reference. When Crossref has none, remile can try an identifier-matched OpenAlex record and reconstruct its abstract from the [word-position index](https://help.openalex.org/data/works/attributes/#abstract_inverted_index). The response and reconstructed text have fixed size limits. An unavailable abstract keeps the other recognised fields. Existing abstracts are preserved. No PDF text is uploaded.

**Include abstract** in Reference settings controls BibTeX copying, export and insertion. Turning it off keeps the library's abstract available to local suggestions without adding it to the manuscript bibliography.

Right-click a record and choose Find a paper. remile checks matching PDFs already open or attached, then looks for a public copy. Choose Attach PDF to keep a confirmed match. The existing record and citation key are retained.

| Available details | Where remile looks |
| --- | --- |
| arXiv ID or arXiv DOI | The public archive, keeping any specified revision |
| PMCID | The public PMC article PDF route |
| DOI or source URL | The source page's PDF metadata or PDF alternate links |
| DOI after other routes fail | OpenAlex public repository and publisher locations |
| Title only | One exact Crossref match, then its public sources |

An advertised PDF link may return a sign-in page, another paper or a chapter. remile checks readable PDF bytes and extracted identifiers or title before offering the file. Whole books also need a matching book title. Uncertain matches stay unattached. Add local PDF lets you attach a copy you have checked yourself.

Lookup runs only on request, with up to eight candidate URLs, a 90-second search budget and a 25 MB file limit. Downloads use temporary storage and are discarded when they fail. The waiting state can be cancelled, and the airplane control blocks online retrieval. No GPT request runs. Source and the repository's reported version appear beside Include PDF during review. A version label from an index is not an independent check of the edition.

### PDF access

Find a paper checks local files and public PDF sources. Subscription-only papers must be downloaded in your browser and added with **Add local PDF…** or dropped onto the reference. Publisher sign-in, embedded browsing and remembered publisher sessions are not available. Existing managed attachments are unchanged.

### Libraries and selection

Right-click the sidebar to create a library or a collection. A collection belongs to one parent library. Move to collection keeps the record's identity. Add to library creates independent metadata while sharing identical PDF bytes.

Command-click selects several rows and Shift-click selects a range. Row context menus offer editing, BibTeX copying/export, attachments and Trash. Delete retains the record and attachments in Trash. Restore returns them. Empty Trash permanently removes discarded records and unshared files after confirmation.

## Columns and keys

Title, Author / Editor, Journal / Publisher, Year and Type are visible by default. Click a heading to sort ascending, then again to reverse. Text uses natural alphabetical order and years use numeric order. Empty values stay last. Drag a heading's right edge to resize it. Widths and visible columns are remembered and included in presets. Title stays visible and starts widest.

Columns share the available space. Saved widths return when the pane is wide enough. On smaller panes, columns shrink to readable minimums before horizontal scrolling is needed. Double-click a column boundary to return that column to automatic sizing. Reference settings → Reset widths restores automatic sizing for every column.

Settings below the sidebar artwork controls columns, citation keys and abstract export. Keys use the first author's surname, or the first editor's surname when no author is recorded, followed by the year and one or two title words. Missing contributors use `Reference`, missing years use `nd`, and collisions receive numeric suffixes. Changing the rule affects new records. Regenerating stored keys can require changes to manuscript citations.

Edited volumes may have editors rather than a single author. Author / Editor shows the editor with `(ed.)` or `(eds.)` when no author is recorded. The metadata inspector and BibTeX export keep the two roles separate. An edited book's empty author field is not necessarily missing information.

Existing keys remain unchanged when metadata is enriched. Use Regenerate citation key explicitly if you want an editor-based key, then update any manuscript citations that use the old key.

Double-click a metadata value to edit it. Return saves and Escape cancels. Stored abstracts appear last, below the dates, in an Abstract section that starts collapsed. Expand it to read or copy the text. Use Edit reference to change the abstract. BibTeX exports omit abstracts unless enabled in Reference settings. Uncommon imported types and fields remain stored.

## Review and Undo

Clean up reviews local metadata proposals and duplicate candidates. Merge selected is available for related records. Review the base record and conflicting fields before merging. Distinct PDFs are retained and extra records are removed without going to Trash. Manuscript citations are not rewritten.

Undo and Redo retain up to 30 session changes within an 8 MB metadata limit. PDF bytes are not copied into Undo. External catalogue changes clear incompatible history. Empty Trash clears Undo.

Reference metadata uses local parsing and verified bibliographic responses. Look up metadata fills missing fields without guessing unknown facts. Read metadata reviews local PDF evidence. Neither action uses a language model.

## Complete a library

Clean up library has Metadata and Duplicates views. Opening it makes no online lookup. **Look up missing** checks records missing contributors, a year or an abstract, with up to three requests in progress. Provider pacing still applies. Stop cancels pending requests and keeps completed proposals for review. **Apply selected** writes only checked changes with revision checks and Undo.

Add PDFs through Add PDF or by dropping them onto a reference. Clean up does not manage missing attachments.

## Storage and other Macs

Settings → Storage offers one location for Reference and search data. Change → Move storage creates a `remile-storage` folder at the chosen location. The change runs before workspaces open on the next launch. remile copies Reference and search data before switching locations and verifies the copied Reference files. Previous files remain intact.

Reference uses `Reference/` and relative attachment paths. Search uses `Search/<Mac identity>/`. Another Mac opens the shared storage through Change → Open storage and keeps a separate search database. Machine identity and storage paths are excluded from presets. Existing customised Reference locations keep working until a storage move is requested.

If copying fails, the active location is unchanged. If the selected drive is missing, reconnect it. Keep cloud files downloaded before opening storage. This uses a local folder or mounted drive, rather than a remote database service.

An opened library starts read only. Catalogue changes, passage saves and saving over managed PDFs are blocked. Copies can be saved outside the library. To edit, turn off Read only on one Mac after folder sync finishes. Wait for changes to finish syncing before editing on another Mac. The local file lock does not coordinate writers on different computers, and remile does not merge cloud conflicts automatically. Keep unresolved conflict files until they have been reviewed.

Keep the library downloaded on every Mac that needs offline access. Apple documents [Keep Downloaded](https://support.apple.com/en-gb/guide/mac-help/mchl1a02d711/mac). Dropbox describes [conflicted copies](https://help.dropbox.com/organize/conflicted-copy) caused by concurrent or offline edits. Shared-folder behaviour is tested with local copies at different paths. Two physical Macs and provider conflict recovery require separate validation.

## Presets

Settings → Storage → Presets offers Save preset and Load preset. A versioned JSON file carries appearance, editor, search, citation-key, column and pane-width preferences. Save separate files for different working environments, or put a preset in Dropbox or iCloud Drive and load it on another Mac. Existing remile settings JSON exports remain compatible.

Loading requires confirmation. Accounts, credentials, network permissions, documents, library paths and read-only access mode stay local. A preset restores the supported preferences it contains. It does not synchronise itself automatically or transfer library data. Reopen a workspace to apply saved pane widths.

## Cite while writing

The book button in LaTeX, Overleaf, Markdown and Search opens the reference picker. **Use for citations** has checkboxes for one or more libraries and collections. These choices are remembered for the current document and used by TeX completion too. Uncheck every library to use only the project bibliography. A reference in both a selected library and collection appears once. Copy citation returns `\cite{key}` for TeX or `[@key]` for Markdown. Markdown rendering depends on the export tool.

In TeX, type `\cite{` to search keys, titles, authors, years and stored abstracts. Without a useful sentence context, project bibliography entries appear before library entries. With context, related sources can appear first. Explicit key prefixes retain priority. Arrow keys select a suggestion, Return or Tab inserts the key, and Escape dismisses. No AI request or PDF analysis runs while typing.

See [Read citation hints](../reference.md#read-citation-hints) for the meaning of Topic match, Limited overlap, No clear match and the source-basis labels. Strong topic overlap is not proof of support, and missing overlap is not proof of irrelevance.

### Citation purpose hints

The engine looks for English cues in the sentence. These are possible, overlapping uses, not a complete classification of scientific citations or a judgement about the source.

| Hint | Possible use | Check in the original source |
| --- | --- | --- |
| **Background** | Introduce a field or describe a trend. | Whether the cited work shows the trend you describe. |
| **Fact or mechanism** | Establish a fact, mechanism or premise. | The actual claim and its physical or experimental conditions. |
| **Method or tool** | Name an algorithm, model or software. | The original method, relevant implementation and version. |
| **Comparison** | Compare results with measurements or benchmarks. | Values, units, uncertainty and matching conditions. |
| **Context** | No clear purpose cue was found. | The passage relevant to your sentence. |

For example, an ML paper may be useful background without supporting a claim about hydrogen ignition. A paper mentioning the right fuels can still use different pressures, temperatures or mechanisms. The hints help you choose what to read. They do not settle those differences.

### What matching uses

A short excerpt comes from the stored abstract, not a generated summary. If a project entry omits its abstract, a selected library can supply one after an identifier match or an exact match of title, contributor names and roles, and year. A key alone is insufficient. This does not rewrite the project entry.

<details>
<summary>Matching limits and resource use</summary>

The engine uses local word overlap, limited abbreviation expansion and exact numeric tokens. It does not resolve contradictions, convert units, verify historical trends across papers or infer experimental agreement. A matching number is not a validated result.

H₂, H2 and hydrogen share a term, as do NH₃, NH3 and ammonia. Water and ammonium remain distinct. Recognised phrases and their abbreviations, such as machine learning and ML, count once rather than adding duplicate terms. Numeric matches alone cannot produce Topic match. These are explicit lexical rules, not chemical or scientific reasoning.

Indexes are reused while writing and refreshed after a catalogue or library-selection change. Retrieval reads up to 2,000 title characters and 12,000 abstract characters per record. Stored metadata and inserted bibliography entries retain their full text. No model, vector database, network request or PDF scan is required while typing.

Markdown retains the reference picker and citation copying. It does not display these inline recommendation labels.

</details>

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
