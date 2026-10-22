# Architecture and decisions

remile. is a native macOS document workspace. The Swift package has one executable target. The directories below are responsibility boundaries, not separate compiled packages.

| Area | Owners | Boundary |
| --- | --- | --- |
| Native readers and persistence | `ReadingSession`, PDF/Markdown sessions | Keep unsaved edits and document identity. Save/Discard owns persistence |
| LaTeX authoring | `TeXProject` and focused compiler/history/outline helpers | Own the active project and buffers. External processes build snapshots |
| Connected projects | `OverleafLibrary` | Account/project metadata, worktrees, review and publication lifecycle |
| Web account access | `OverleafWebIdentity`, `OverleafWebClient`, `OverleafSignInSession` | Per-profile remile. session, read-only JSON endpoints and bounded login surface |
| Current source synchronisation | `OverleafGit`, `OverleafAutoPublisher`, `OverleafAutoSync` | Versioned Git transport, worktree fingerprints, isolated review copies and normal pushes |
| Opt-in live text synchronisation | `OverleafLiveWorkspace`, socket, wire, text and journal helpers | One project writer, native editor transport and preserved drafts. Real-server validation pending |
| Network policy | `NetworkAccessGate` | Reject and cancel app-owned network operations. No operating-system firewall claim |
| Local automation | `EditorCLI`, `EditorBridge` | Structured responses, explicit document identity and expected hashes for edits |

## Decisions

### Keep one native executable with cohesive source modules

Use the platform’s PDF, WebKit, Security and text APIs with focused helpers rather than adding dependencies by default. This reduces distribution weight, but does not remove ownership of parsing, failure handling or compatibility. Add a dependency when a demonstrated requirement and validation justify it. Move responsibilities out of a large observable object when lifecycle or ownership becomes unclear. Source line count alone is not a refactoring trigger.

### Separate account browsing from Git capability

A web session lists projects and reads comments. A Git token authorises the Git bridge. Neither proves the other capability. Restore and verify the saved web session before presenting login. Request a Git token when importing, and distinguish a missing token, locked Keychain, expired login, access refusal and temporary service failure. Internal web endpoints remain a compatibility risk. Fixture checks do not prove the current service contract.

`OverleafSessionAccess` shares concurrent restores per profile and backs off denied silent reads for 30 seconds. When the saved backup needs approval, try remile.'s existing WebKit session before requesting connection recovery. Keychain denial alone does not prove that the login Keychain is locked. The connection screen offers explicit saved-session approval or a new sign-in. Background reads and backup writes suppress interaction without changing item access permissions or device-only protection. Unchanged cookie backups avoid repeated writes. Optional catalogue refresh failures stay inside the library rather than opening a global alert.

### Preserve drafts during reconciliation

Git review stages live outside active source buffers. Compare both the expected worktree fingerprint and remote head before applying or publishing. Use normal pushes, never force pushes. Local-only edits may publish automatically while an Online project is open. New remote revisions pause automatic publication for explicit review. This protects authors’ drafts. It is not live collaborative editing.

### Prepare real-time transport separately

The opt-in live workspace and Git lifecycle share one project writer lease. Live mode blocks Git publication until it stops. Stopping leaves automatic Git publication paused for review. The native legacy editor adapter uses the app-owned web session, applied acknowledgements and fresh snapshots. Do not open an editor socket as an incidental effect of account login. Existing text documents are supported. Structural changes and overlapping edits require review. See [live synchronisation](overleaf-realtime.md) for recovery, bounds and remaining real-server validation.

### Make PDF protection explicit

The reader always shows a lock: a muted closed lock means no editing protection was detected, an active closed lock means signature/certification consent or document restrictions apply, and an open lock means the user explicitly allowed protected editing. Entering Edit PDF checks protection before changing modes and shakes the lock when blocked. Consent never overrides encryption or PDF permissions. Signature/certification detection is conservative and does not establish cryptographic validity or certificate trust.

New notes use a standard PDF comment icon in muted gold. Reply cards show a connector and immediate-parent context. Their relationships remain standard PDF reply metadata. Page-icon deletion uses the same protected, undoable annotation transaction as sidebar deletion. Live connection errors use a short status control with a wrapping detail popover rather than a truncated diagnostic sentence.

### Keep verification claims specific

The local check scripts run the actual Swift implementations with temporary fixtures. The Git checks use a synthetic loopback smart-HTTP remote. Real-time checks use fake transports. These are native regression checks, not an XCTest target or evidence of a real Overleaf handshake. Native renders, executable signatures and installed CLI checks are separate evidence. No remote CI result is implied.

## Overleaf regression entry point

Run the focused groups together with the current host’s verified Python:

```sh
zsh tools/check_overleaf_safety.sh /absolute/new-output-directory /absolute/python
```

The output directory must be new. Each group has its own log. `summary.json` records the source commit and synthetic scope after all groups pass. The entry point runs Git reconciliation/publication, comment parsing/export, account connection and artwork, real-time preparation and title-bar routing checks. It does not build/install an app, contact an Overleaf account or publish remote project changes.

For a live check, first verify account-list access and the configured Git branch without publishing. An end-to-end publication test should use a disposable project or an explicitly selected test change, record the starting heads and local draft state, and check both sides after reconciliation. Do not claim live real-time compatibility from fake-channel or framing checks alone.
