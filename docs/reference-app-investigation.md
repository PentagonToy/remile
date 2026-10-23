# Reference application investigation

23 October 2026. This is a first static investigation of the three installed applications selected by the user. It informs the [agent and library strategy](agent-library-strategy.md). It does not implement a reference manager or an external-library adapter.

## Outcome for remile.

Prioritise one application command layer that serves the UI and CLI, explicit item and attachment identities, and independent metadata/text/original-file availability. These recommendations follow from the observed module boundaries below. They do not require remile. to adopt another application's framework, code or storage format.

The local Reference implementation now occupies this Home destination. See [Reference](reference.md) for its current behaviour. External-library adapters remain deferred.

## Installed targets and evidence

| Target | Installed declaration | First-pass observations | Limits |
| --- | --- | --- | --- |
| ReadCube | `com.ReadCube.Papers`, 5.2.3 | Electron bundle with a Go storage sidecar. Shipped source-map material describes shared CLI/MCP command dispatch, 21 MCP tool schemas, a separate metadata/offline queue and evictable PDF cache, attachment-hash-specific annotations and import adapters | Static source-map and binary metadata. No live listener, backend transaction, import fidelity or runtime performance test |
| Zotero | `org.zotero.zotero`, 9.0.6 | Shipped local API has GET routes and an enabled-preference check. SQL separates item keys/versions, attachments and annotations. Storage distinguishes on-demand downloads. A separate full-text engine exchanges versioned extracted text | Three selected JavaScript modules analysed by REA, with supplementary reads of exact packaged SQL/source members. No local API request, personal DB read or cloud test |
| EndNote 2025 | `com.ThomsonResearchSoft.EndNote`, 22.4.0.23050 | Native universal executable links AppKit/PDFKit/WebKit. A shipped scripting dictionary declares 21 semantic commands. Native metadata exposes record, attachment, PDF-indexing and conflict entry points. Bundled help documents library and export behaviour | Method declarations and help are not observed execution. Native metadata inspection was bounded. DB schema, live scripting and cloud protocol remain unknown |

Versions describe the installed artifacts, not the latest vendor releases. All three applications were inspected without launching them, accessing accounts or reading personal libraries. No vendor source was copied into remile. implementation code. Complete REA Evidence and exact member provenance are retained outside the repository.

## CLI and agent access

ReadCube's shipped CLI and MCP adapters call the same command bridge, with request IDs, structured results/errors, pending-call tracking and a 30-second timeout. Its MCP catalogue includes explicit collection/item targets. The packaged preference defaults MCP to disabled. This does not establish a currently running listener or GUI-independent CLI. The useful pattern for remile. is the common command boundary, not a reason to open a network service now.

Zotero's packaged local API module declares reads for items, collections, schemas, saved searches, cached full text and file locations. It checks a local preference and API version. Its local API file describes writes as unsupported, and the inspected route classes declare GET. Do not generalise this to every Zotero interface or assume the feature is enabled on this Mac. A future read adapter should negotiate capabilities and apply its own output limits, rather than relying on unbounded defaults.

EndNote's scripting dictionary provides record-level search, field/XML reads and writes, creation/deletion, groups and formatting. Its scripting export parameter is RSXML, while bundled GUI help separately describes BibTeX/RIS output styles. A feature available in the GUI is not automatically available through its scripting adapter. No script was executed.

For remile., finish explicit document targeting, stable command/result schemas and timeout-outcome recovery before exposing more writes. Share domain operations between adapters and views. Future capability discovery should state reads, writes, export formats, app requirements and network behaviour independently. Do not claim current remile. has those new discovery commands.

## Library identity, attachments and search

Zotero's shipped schema gives items a library-scoped key and version, separate attachment records with storage state/hash, and separate annotation records with parent attachment, position, page label and external status. Its source distinguishes imported and linked attachments. The full-text engine has its own item/library versions and bounded upload batches. This supports the proposed separation of metadata and extracted text from heavy original bytes. It does not prove identical behaviour for arbitrary iCloud/Dropbox folders.

ReadCube's shipped storage boundary distinguishes account-specific metadata and queued edits from cached or pinned PDFs. Annotation operations include an attachment SHA-256, which prevents confusing annotations belonging to different files on the same reference. Export code describes staging, streaming, cancellation, collision-safe names and partial-success outcomes. The Go sidecar's SQLite dependency is embedded metadata. Its transactional implementation was not recovered.

EndNote's bundled help describes an `.enl` file with an accompanying `.Data` folder and warns that record numbers can change during copying or synchronisation. Preserve imported external identifiers as provenance rather than making them remile.'s permanent identity. The inspected native entry points and help distinguish PDF indexing, PDF reading/annotation and reference search, but do not establish their indexing algorithms.

Keep stable internal item/attachment IDs, content revisions, lightweight annotation records and a rebuildable local index. Model missing or evicted PDFs as an availability state. Cache clearing must preserve metadata, queued changes and unresolved conflicts. These are design recommendations, not newly implemented library behaviour.

## Integration and recovery

ReadCube packages separate Zotero/EndNote import converters. EndNote exposes different format capabilities through GUI and scripting. Zotero's local API maps multiple export formats. Together these observations favour independent adapters that return a canonical model plus attachment references and per-item outcomes. Prefer declared APIs or user-exported formats before depending on private DB layouts.

The EndNote help describes conflict selection that discards the unchosen revision. This is a documented product behaviour, not a policy to copy. remile. should preserve both revisions and make recovery inspectable. Current Live recovery still needs measured deduplication and retention work before its approach could serve large PDF libraries.

## Evidence ledger

All paths below are local execution evidence for this installed-artifact pass. Supplementary source/SQL/dictionary reads have recorded original member hashes and locations. REA JavaScript parsing was inert. Recovered declarations and source-map text do not prove that the corresponding path runs in the installed product.

| Scope | REA Evidence | Retained files |
| --- | --- | --- |
| ReadCube package | `ev_88f50109f137dc5893a74b88a14ca44fe15aa70a7f558e82b7d1e5c7d6faef76` | [Detailed ReadCube findings](/Volumes/PentagonToy/Workspace/Agents/Repository/remile/2026-10-23-reference-preparation/rea-readcube/findings.md) |
| ReadCube CLI/MCP source-map selection | `ev_734908b87d9716c893833cf7ac6f9f1716c7b3b7e6e579daf301405989c81c16` | `rea-readcube/03-agent-interface-evidence.json` |
| ReadCube storage/import/export selection | `ev_c678ef5b1bd42f5c97a1e897fcb74fc91ee656d372ab8cc15c50a539c9d147e0` | `rea-readcube/04-storage-export-evidence.json` |
| Zotero bundle inventory | `ev_82cad389bc2d6b0eb7aed494155cf3482612750dc5107a8efa9d2dd6e448e4fe` | `rea-zotero/artifact.json` |
| Zotero plist | `ev_3266a5e1ca1840b1b33253ed9f3cd2f3fc29a911b3ab0c6cb6fea77947eed08d` | `rea-zotero/plist.json` |
| Zotero selected API/storage/full-text source | `ev_5fc3a3055111ff5fb65e4f5feb2f84b1dcbc7cb5aaff1dff97e743c54e9111e4` | [Detailed Zotero findings](/Volumes/PentagonToy/Workspace/Agents/Repository/remile/2026-10-23-reference-preparation/rea-zotero/findings.json), `javascript.json`, `source-provenance.json` |
| EndNote bundle inventory | `ev_6b2387b07fabe784fa8793202a5fceab8a39838af692fa06435b321d7c961093` | [Detailed EndNote findings](/Volumes/PentagonToy/Workspace/Agents/Repository/remile/2026-10-23-reference-preparation/rea-endnote/findings.md) |
| EndNote plist/native metadata | `ev_5fc93a0eda4d63c7b283e04e535f7b13949e2d3f39f951e36decdb94868efa92`, `ev_e4eff65d38f86612b15c81b006209e333fa9678dbe4f8c46807d625e181f1b5f` | `rea-endnote/plist.json`, `dispatch.json`, `resource-provenance.json` |

Relative evidence filenames in this table are under `/Volumes/PentagonToy/Workspace/Agents/Repository/remile/2026-10-23-reference-preparation/`. Full product reconstruction, dynamic interoperability and performance remain outside this first pass. No reference-management implementation beyond the explicitly requested placeholder was added.
