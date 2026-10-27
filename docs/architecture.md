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
