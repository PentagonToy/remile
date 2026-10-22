# Live Overleaf synchronisation

Git remains the default. The development implementation adds an opt-in Live sync control for existing text documents while a project is visible. It uses remile.'s own Overleaf web session and a native Socket.IO 0.9 adapter. No Node runtime or browser cookie import is required. WebKit supplies the verified account context while Swift owns protocol routing and document state. Live mode joins Overleaf's collaboration session, so it does not retain the private-presence behaviour of Git sync. Installed development checks cover text round trips, conflicting drafts and controlled connection-loss recovery. Broader collaboration validation remains necessary before release.

## Ownership and lifetime

`OverleafLiveWorkspace` owns the visible project's text session. Git review, automatic publication and project removal share its project-level OS writer lease. Git checks take that lease before saving buffers. While live mode is enabled, Git cannot publish, including after a live connection failure. Stop live releases the lease but leaves automatic Git publication paused until project review. Closing the project cancels the socket and pending requests. No daemon or background permission is used.

Offline mode cancels app-owned network sessions. Live mode remains paused until an explicit reconnect, which reads fresh snapshots before publishing. Project identity changes create a new visible-session owner. Connection recovery uses the same per-account web sign-in screen as project browsing. A Git token does not authenticate the editor socket.

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

The project bar shows a direct Private / Live selector and one current status. Comments, the library and connection settings have visible buttons. Connection settings contain the offline switch, account management and any Git unlock action. Narrow windows shorten status labels and show compact action icons. Git checking is shown only outside Live mode. PDF freshness remains beside Compile because server confirmation does not mean the PDF has been rebuilt.

The project bar distinguishes connecting, paused, awaiting server confirmation and confirmed states. Pending counts include every connected text file, including edits made before the next upload. Confirmation advances only when no document has pending intent and reconciliation has finished. Idle polling does not advance the confirmation time. A closed event stream pauses Live even when no explicit error frame arrives. The pause label gives a short reason, with the full explanation available from the label. Passive Git sync waits for an explicit Unlock action when Keychain access is locked, without repeating error dialogs.

## Draft preservation

Persist the operation intent before sending. Edits made during an upload remain in the buffer and are reconciled against the acknowledged upload and fresh server text. A timeout or disconnect retains uncertain intent. Reconnect does not blindly replay it. Unconfirmed divergent uploads require review. Same-position inserts and overlapping replacements also require review rather than silently choosing one author.

Conflict records retain both texts with private permissions. A persistent review marker prevents reopening from silently treating the local draft as an authorised overwrite. The review highlights changed sections with nearby context. Choose local or Overleaf for each section, or keep one complete version. Every choice rechecks both the current local draft and remote snapshot before applying the result. Newer changes cause another review. Each installed source update compares the expected editor text and existing disk content. Unexpected disk edits or symlinks stop the session.

Checkpoints live outside the project worktree and contain no cookies or Git tokens. Text is bounded to 2,000,000 UTF-8 bytes. Protocol frames and encoded journals are bounded separately. UTF-16 offsets cannot split surrogate pairs. Malformed IDs, paths, deletions, versions or recovery data fail closed.

## Current limits and verification

Live sync covers existing text documents already loaded by the LaTeX editor. Entity creation, rename, deletion, folder changes and binary replacements stop the live session for Git review. They are not silently mirrored. Reconciliation uses unchanged line anchors and refines each changed block to character boundaries. Disjoint changes combine, identical edits are included once and overlapping edits require review. The line comparison is capped at 250,000 cells and 2,000 lines per side. More complex changes fall back to one conservative range. Separate edits within one changed line can still request review. A structure-change pause offers Stop live and review Git. This releases Live ownership and opens a Git check while automatic publishing stays paused. Read-only accounts cannot start a writable socket. Unsupported protocol responses and browser verification remain visible failures. No login or TLS policy is bypassed.

Run `zsh tools/check_overleaf_realtime.sh /absolute/new-output-directory` for wire framing, Unicode operations, conservative merges, checkpoint recovery, writer exclusion and offline/cancellation checks. `tools/check_overleaf_connection.sh` also runs the actual visible workspace against a fake project channel and temporary Git worktree: transformed acknowledgement, edits during upload, ownership, conflict persistence and explicit review. These tests do not establish real-server compatibility, collaboration latency or installed Keychain approval. Keep those live results separate from synthetic checks.

Installed-app checks against `remile_sample` joined 19 text documents and covered two-way edits, same-position conflict preservation, explicit review and offline reconnect. The session remained connected for about eleven minutes, handled heartbeat frames and completed another text round trip afterwards. Idle polling did not advance its confirmation timestamp. All temporary comments were removed and the web and local content matched the connected baseline.

A separate real-server check withheld applied-update delivery at the test transport boundary and closed the socket after submitting a comment. Pending intent survived. Reconnect recognised the applied server snapshot without replaying the submission, then removed the comment. This verifies controlled response-loss recovery. It does not establish system-wide outage behaviour, hours-long stability or a fresh OS Keychain approval path.

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
