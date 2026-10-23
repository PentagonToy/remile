# Agent access and library architecture

## Current implementation

Reference is a local bibliographic library with PDF/BibTeX import, collections, managed shared attachments, reviewed duplicate merging, fixed citation-key rules, metadata editing and explicit public-paper lookup. See [Reference](reference.md). The earlier placeholder and preparation stages are complete. The [application investigation](reference-app-investigation.md) records the bounded static evidence that informed the design, without copying vendor code.

The UI and Reference CLI use ReferenceRepository. A single atomic catalogue snapshot supplies records and library identities. Writes use a catalogue lock, atomic replacement and expected revisions. Stable UUIDs identify references and attachments independently of filenames. Byte-identical PDFs share storage, while separate libraries can retain independent metadata and keys. Parsing, display rendering, PDF extraction, merge planning, public metadata lookup and SwiftUI presentation have separate owners.

| Module | Responsibility |
| --- | --- |
| Automation/EditorCLIArguments | Validate options before file access or dispatch |
| Automation/EditorCLI and EditorBridge | Route commands and running-document requests |
| ReferenceRecord, ReferenceLibrary | Bibliographic and attachment identity, revisions and collections |
| ReferenceRepository | Catalogue transactions, managed storage and recovery boundaries |
| ReferenceBibTeX, ReferenceText, ReferencePDFMetadata | Format parsing, readable labels and fallible local PDF evidence |
| ReferenceMergePlan, ReferenceCleanup | Ranked field proposals and explicit review |
| ReferencePaperLookup | User-triggered metadata/public PDF retrieval with network and size limits |
| ReferenceCLI | Bounded reads, revision-checked writes and new-file BibTeX export |
| ReferenceModel and native views | Asynchronous operations, selection and presentation |

Reference commands do not depend on the active window. Use `reference libraries`, then `reference list --library UUID`, `reference show --id UUID` or `reference export --library UUID --output /absolute/new.bib`. Library discovery includes collection parents. List summaries are paginated and field-bounded, with an explicit truncation flag. Show returns stored fields and revisions. Export refuses an existing output file. Import requires an explicit destination. Metadata update, attachment changes, Trash/restore and key regeneration require a record ID and expected revision. Native views observe external writes through directory events. Permanent deletion, merge and network lookup remain native actions.

The document CLI shares live editing behaviour with the application. Source edits require a SHA-256 and preserve Undo. Unknown, repeated and incomplete options, malformed numbers and overflowing ranges are rejected before dispatch. The documents command discovers open session identities. Live document commands accept an explicit --target UUID and reject closed or reopened sessions without falling back to another window. Omitting the target retains active-window behaviour. Agents must inspect `status` before editing and cannot infer an operation's outcome from a timeout alone. Search uses the existing local LibraryIndex and SQLite FTS5 store. `--no-boost` selects its local keyword route. Passage citations and bibliographic records remain separate concepts.

## Remaining CLI work

Keep command spellings and JSON contracts stable. Add machine-readable command discovery and stable error codes before expanding live mutations. Generate help and machine discovery from one descriptor when that contract is implemented. Do not claim that these features already exist.

Queued writes need expiry, cancellation and recoverable operation identities. A timeout must not encourage blindly repeating a write. Long indexing, compilation and import operations should eventually expose bounded status reads. Future CLI merge and cleanup should expose reviewable proposals and explicit apply through the shared repository service. Current direct metadata writes use expected revisions. Credentials remain inside the application.

## Deferred storage work

General Settings already transfers an allowlisted preference file manually. Cloud Reference roots, library migration, cross-device library synchronisation, RIS import, full-text Reference indexing and external application adapters remain unimplemented. No empty wrappers or account connections are needed for this preparation.

Keep active SQLite/WAL files and device caches local. A future portable authoritative layer needs relative attachment references, availability states, revision conflicts, tombstones and backup/restore. Do not place an open database in a cloud folder. A future immutable extracted-text cache could let another device rebuild its local index without fetching every original PDF. Treat metadata, text and original-file availability separately.

Measure command latency, main-actor responsiveness, resident memory, bytes read and recovery growth before adding broad caches or changing search ranking. Current optimisations remove repeated catalogue decoding and rebuild sidebar counts outside the main actor. No measured search speedup is claimed. Live recovery retention and content-hash deduplication still need a separate measured design that preserves unresolved recovery evidence.

## Remaining acceptance checks

- Operation recovery reports an outcome without blindly repeating a mutation.
- A moved library root preserves item identities and citations.
- An unavailable cloud folder never removes metadata or indexed items.
- Concurrent cross-device changes retain both versions for reconciliation.
- Cache eviction preserves originals, notes and unresolved recovery data.

These checks apply to deferred features. Current local import, revision, merge, attachment and CLI contracts have focused synthetic regression checks under Tests/ReferenceChecks, Tests/CLIArgumentChecks and Tests/AutomationTargetChecks. The latter verifies writes to one of two open projects with identical source hashes, plus stale-session rejection.
