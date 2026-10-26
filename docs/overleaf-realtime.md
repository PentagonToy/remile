# Live Overleaf synchronisation

Projects start in Live mode while visible. An explicit choice of Private is remembered for that project. Private uses Git review for Git-backed imports. Live combines versioned text edits with file reconciliation. It uses remile.'s own Overleaf web session and a native Socket.IO 0.9 adapter. No Node runtime or browser cookie import is required. WebKit supplies the verified account context while Swift owns protocol routing and document state. Live mode joins Overleaf's collaboration session, so it does not retain the private-presence behaviour of Git sync. Installed development checks cover text round trips, conflicting drafts and controlled connection-loss recovery. Broader collaboration validation remains necessary before release.

## Ownership and lifetime

`OverleafLiveWorkspace` owns the project's text session. Git review, automatic publication and project removal share its project-level OS writer lease. Git checks take that lease before saving buffers. While live mode is enabled, Git cannot publish, including after a live connection failure. Stop live releases the lease but leaves automatic Git publication paused until project review. One recently closed project can stay available for 45 seconds for a quick return. Hidden file checks stop, and expiry closes the session. No daemon or background permission is used.

Brief transport failures reconnect automatically with bounded backoff while preserving Live mode and the local draft. Work offline cancels online work and suppresses retries until online access returns. Recovery reads fresh snapshots before sending. Authentication, permissions, rate limits and real conflicts remain explicit issues. Project identity changes create a new session owner. A Git token does not authenticate the editor socket.

The detached WebKit transport disables idle suspension only for its active lifetime so that heartbeat replies can run. Closing it restores suspension. RPC decoding accepts both data-bearing and empty Socket.IO acknowledgements. An empty RPC acknowledgement confirms receipt only. The workspace still waits for `otUpdateApplied` and a fresh document snapshot before confirming a source update. Document leave requests also use the acknowledged RPC form.

## Modules

| Module | Responsibility |
| --- | --- |
| `OverleafLiveWire` | Bounded legacy framing, project tree identity/path validation, line decoding and ShareJS operation payloads |
| `OverleafLiveBrowser` | Account dashboard, standard browser handshake/WebSocket and app-owned cookie context. No editor page or cookie export |
| `OverleafLiveSocket` | Native heartbeat replies, RPC correlation, applied-update events and cancellation |
| `OverleafLiveText` | Validated UTF-16 operations and conservative reconciliation of disjoint character ranges |
| `OverleafLiveWorkspace` | Editor/disk reconciliation, one pending upload per document, server refresh after applied acknowledgement and conflict decisions |
| `OverleafLiveJournal` | Private checkpoints, conflict recovery and the OS project writer lease |
| `OverleafLiveState` / `OverleafLiveCoordinator` | Bounded operation/identity contract and separately tested transport-independent orchestration |

The older coordinator deliberately requires review for divergent snapshots. The visible live workspace adds conservative reconciliation around that contract: clean remote updates and disjoint local changes can combine automatically. Overlapping intent requires a choice. It does not implement a general client-side OT transform. Overleaf transforms submitted operations, and the workspace rejoins the document after an applied acknowledgement before accepting the resulting server state. The initial RPC reply only means the update was queued.

## Connection status

The project bar shows a direct Live / Private selector and one current status. Comments, the library and connection settings have visible buttons. Connection settings contain the offline switch, account management and any Git unlock action. Narrow windows shorten status labels and show compact action icons. Git checking is shown only outside Live mode. PDF freshness remains beside Compile because server confirmation does not mean the PDF has been rebuilt.

The project bar distinguishes connecting, paused, awaiting server confirmation and confirmed states. Pending counts include every connected text file, including edits made before the next upload. Confirmation advances only when no document has pending intent and reconciliation has finished. Idle polling does not advance the confirmation time. A closed event stream pauses Live even when no explicit error frame arrives. Click Paused to reconnect, or to review conflicting text when present. The reason remains available in native hover help. Passive Git sync waits for an explicit Unlock action when Keychain access is locked, without repeating error dialogs.

If the advertised file tree changes while the source archive is downloading, the initial snapshot is checked again up to three times. A stable snapshot enters ordinary three-way reconciliation automatically. Repeated changes pause with a reconnect action. Conflicting local and remote edits still require review.

## Draft preservation

Persist operation intent before sending. Edits made during an upload remain in the buffer. Recovery checks the server snapshot and complete catch-up history for the original operation. If it was applied, newer local typing is reconciled against that result. Otherwise, a journal with known connection source IDs can replay the exact original operation and version with `dupIfSource`, allowing the server to suppress a duplicate. A foreign empty operation or comment anchor cannot acknowledge a local upload.

Older journals without reliable source IDs remain conservative. Unconfirmed divergent uploads, overlapping replacements, same-position inserts and incomplete history require review. Source-ID replay and lost-acknowledgement recovery are covered by fake transports and read-only upstream protocol inspection. This new recovery path has not been verified against the deployed server or a real Wi-Fi outage.

Conflict records retain both texts with private permissions. A persistent review marker prevents reopening from silently treating the local draft as an authorised overwrite. The review highlights changed sections with nearby context. Choose local or Overleaf for each section, or keep one complete version. Every choice rechecks both the current local draft and remote snapshot before applying the result. Newer changes cause another review. Each installed source update compares the expected editor text and existing disk content. Unexpected disk edits or symlinks stop the session.

Checkpoints live outside the project worktree and contain no cookies or Git tokens. Text is bounded to 2,000,000 UTF-8 bytes. Protocol frames and encoded journals are bounded separately. UTF-16 offsets cannot split surrogate pairs. Malformed IDs, paths, deletions, versions or recovery data fail closed.

## Current limits and verification

Live text reconciliation uses unchanged line anchors and refines changed blocks to character boundaries. Disjoint changes combine, identical edits are included once and overlapping edits require review. The line comparison is capped at 250,000 cells and 2,000 lines per side. More complex changes fall back to one conservative range. Separate edits within one changed line can still request review. Read-only accounts cannot start a writable socket. Unsupported protocol responses and browser verification remain visible failures. No login or TLS policy is bypassed.

## Risk boundaries

| Situation | Behaviour | Remaining limit |
| --- | --- | --- |
| Both sides change separate text ranges | Combine edits and preserve typing made during upload | Separate edits within one complex changed line can still need review |
| Both sides change overlapping text | Preserve copies and ask for a decision | Private provides deliberate Git review for Git-backed projects |
| Connection fails after an upload | Check fresh snapshots and operation history before known-source replay | The new replay path still needs deployed-server validation |
| A file changes during rename, replacement or deletion | Stop installation or keep recovery copies | Web file routes lack the Git route's commit-level comparison guarantee |
| Authentication or editing permission changes | Stop and show the account issue | Do not retry permissions or bypass browser verification |
| An agent reads through the CLI | Return source hashes, provenance and local Live observations | A confirmed observation is not a fresh atomic read of the remote project |

Live retains the writer lease through transient failures. Private is an explicit review option, not an automatic fallback that can start a competing writer.

## File changes

`OverleafLiveFiles` validates the remote entity tree and compares a persisted three-way manifest. `OverleafFileSync` coordinates authenticated source snapshots, local file checks, recovery copies and editor installation. File additions, deletions and image replacements trigger automatic reconciliation, followed by a fresh text session. Local file renames are represented as a new path and deletion of the old path. Directories containing synced files are created as needed. Empty-folder changes and hidden metadata are not mirrored. Existing joined source contents remain under the OT journal rather than an unversioned file upload.

Normal files are limited to 30 MB each and 100 MB per project snapshot. Paths, duplicate names, symlinks and snapshot membership are checked before installation. A two-second asset scan detects external image replacement and file membership changes. Source deletion is checked before reading the next OT source. Changes made while a file request is pending invalidate the local installation instead of replacing newer editor content.

Idle asset checks hash files in 256 KiB chunks instead of loading a complete project snapshot. They retain the same fingerprint and path validation, include source filenames without rereading source bodies, and honour cancellation. Comment-only updates and confirmations that leave source text unchanged do not rewrite its file. Unchanged editor buffers avoid repeated text validation. Stopping Live releases its in-memory source caches while retaining editor buffers and durable recovery journals. These changes do not relax conflict checks or increase existing file limits.

For a Git-backed Premium project with an accessible saved token, `OverleafGitLiveFiles` starts from the latest remote branch in a private worktree. It checks each affected path against the web preflight, changes only the planned paths, then makes a normal non-force push. A concurrent server commit rejects the push. The open worktree's HEAD and index are preserved. Separate private Git refs retain the pre-operation local snapshot and accepted publication. Git-backed projects also keep these local recovery copies when the web route is used because a token is unavailable.

For source-only projects, `OverleafFileService` uses the editor's ordinary CSRF-protected upload, rename and delete routes in remile.'s own authenticated WebKit profile. Uploads use unique staging names. Replaced or deleted entities are first parked under unique recovery names. Their bytes are downloaded again before cleanup. A private pending-operation record reconciles an interrupted request against current remote entities before another upload. Concurrent replacement or deletion versus editing pauses with recovery copies. These web routes provide no atomic content compare-and-swap guarantee, so this is a conservative client-side check rather than the Git path's commit-level concurrency guarantee.

Local, remote and post-operation copies are retained outside the project under `Overleaf/LiveFiles/<connection>/Recovery`. The paused bar offers Recovery copies, and Git-backed projects retain explicit Git review. Confirmed temporary remote files are removed, while an uncertain or changed parked file is retained for review. Recovery copies are not automatically purged. Normal Git publishing remains paused while Live owns the project.

Run `zsh tools/check_overleaf_files.sh /absolute/new-output-directory` for file planning, staging, lost replies, racing edits, external file changes, workspace reconnection and a real local Git-server push race. The normal Free import and text regression checks use `tools/check_overleaf_free.sh`. These local checks do not prove compatibility with a particular live server or hours-long stability. Record actual account observations separately.

Run `zsh tools/check_overleaf_realtime.sh /absolute/new-output-directory` for wire framing, Unicode operations, conservative merges, checkpoint recovery, writer exclusion and offline/cancellation checks. `tools/check_overleaf_connection.sh` also runs the actual visible workspace against a fake project channel and temporary Git worktree: transformed acknowledgement, edits during upload, ownership, conflict persistence and explicit review. These tests do not establish real-server compatibility, collaboration latency or installed Keychain approval. Keep those live results separate from synthetic checks.

Earlier installed-app checks covered two-way text edits, heartbeats, conflict preservation and controlled response loss. The new known-source replay path has focused synthetic coverage and still needs deployed-server validation. Neither establishes system-wide outage recovery or hours-long stability.

## Real-server release checks

Use the designated `remile_sample` project and preserve its starting content. Use unique temporary comments for editable probes and remove only those comments after verification. Keep local regression results separate from actual server observations.

| Scenario | Required observation |
| --- | --- |
| Same-range edits from remile. and Overleaf | Both drafts remain available and an explicit decision is required |
| Disconnect during upload | Pending intent survives and reconnect reads fresh server state before any resend |
| Connected idle session | Record duration and heartbeat responses, then verify a text round trip |
| Multiple pending files | One file's confirmation cannot mark the whole project confirmed |
| Keychain approval | A locked connection gives a usable recovery path and a fresh OS approval is verified separately |

A brief successful connection does not establish long-session reliability. Record the actual duration and any untested cases with the build identity.

The controlled real-server check is opt-in: set `REMILE_LIVE_SERVER_CHECK_PROJECT=remile_sample`, then run `tools/check_overleaf_live_server.sh /absolute/fresh-evidence-directory /absolute/built/remile.app`. Stop other Live writers first. It uses the saved account session, sends a unique comment, suppresses applied-update delivery at the test transport boundary and closes the real socket. It then checks retained intent, fresh-snapshot recovery without replay, and comment removal. It does not simulate a system-wide internet outage. A failed or interrupted run retains its evidence and probe marker for manual review. This check is excluded from ordinary offline tests and does not install an app.
