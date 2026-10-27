# Architecture and decisions

remile. is a native macOS document workspace. The Swift package has one executable target. The directories below are responsibility boundaries, not separate compiled packages.

| Area | Owners | Boundary |
| --- | --- | --- |
| Native readers and persistence | `ReadingSession`, PDF/Markdown sessions | Keep unsaved edits and document identity. Save/Discard owns persistence |
| LaTeX authoring | `TeXProject` and focused compiler/history/outline helpers | Own the active project and buffers. External processes build snapshots |
| Connected projects | `OverleafLibrary` | Account/project metadata, worktrees, review and publication lifecycle |
| Web account access | `OverleafWebIdentity`, `OverleafWebClient`, `OverleafSignInSession` | Per-profile remile. session, read-only JSON endpoints and bounded login surface |
| Current source synchronisation | `OverleafGit`, `OverleafAutoPublisher`, `OverleafAutoSync` | Versioned Git transport, worktree fingerprints, isolated review copies and normal pushes |
| Live text and file synchronisation | `OverleafLiveWorkspace`, socket, wire, text and journal helpers | One project writer, native editor transport and preserved drafts |
| Network policy | `NetworkAccessGate` | Reject and cancel app-owned network operations. No operating-system firewall claim |
| Local automation | `EditorCLI`, `EditorBridge` | Structured responses, explicit document identity and expected hashes for edits |

## Design principles

Use native macOS APIs and focused source modules. Add dependencies only when they solve a demonstrated need.

Keep document identity, unsaved buffers and user decisions separate from disposable previews and caches. Save and export have explicit destinations.

Live and Private share one project writer. Git review compares the expected local and remote versions before publishing. Account browsing, Git access and Live transport remain separate capabilities.

Search prepares document structure and scientific aliases during indexing. It stores a replaceable numeric ranking cache locally. Changed documents update their derived text, and global ranking weights are recomputed when needed.

The CLI uses the same document operations as the interface. Editing requires explicit targets and matching revisions. Online work passes through the shared network gate.

## Development checks

Focused checks live in `tools/check_*.sh`. Use temporary fixtures and an external output directory. Check changed behaviour without repeating unrelated validation. Builds, installation and live-service checks are separate actions.


## Bounded editor assistance

Find uses one local source snapshot while its bar is open. Searches are debounced and run away from the UI thread. Results hold at most 20,000 matches. Replace All is unavailable for a truncated result, and source changes invalidate a pending replacement. A regular-expression search has a progress deadline. Very large sources or replacement output are rejected with a short message. Closing the bar cancels work and releases the snapshot. The current implementation limits search input to four million UTF-16 units and replacement output to twice that size.

Project completion is a lazy actor-owned index over existing TeX buffers. It checks the selected file first, then at most 128 files, with a 256,000 UTF-16 unit prefix per file and two million units overall. Unchanged prefixes reuse parsed labels and definitions. It does not create a language-server process, crawl TeX installations or request a network service. A definition beyond the budget can be absent from suggestions without affecting compilation.


The PDF sidebar avoids per-frame document resizing when it opens or closes. The panel alone fades and moves for 180 ms, with one document resize at each endpoint. Rapid reversals cancel pending hide work. Thumbnail jobs are cancelled when the pane is hidden. Recent bitmap previews use a least-recently-used cache capped at 8 MiB and 32 entries. Weak page references avoid retaining closed PDF documents. Rotation and document-edit revisions invalidate cached previews. This cache limit does not bound PDFKit's own memory use or the entire application.
