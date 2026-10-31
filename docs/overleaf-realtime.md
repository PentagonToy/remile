# Online Overleaf synchronisation

Online keeps a local project connected through Overleaf's Git integration. On-device keeps editing and compilation on this Mac without synchronising. The project remembers your choice. New connections start Online.

## Connection states

| State | Meaning |
| --- | --- |
| Unsaved changes | Edits are still in the editor buffer and have not been saved on this Mac. |
| Synced | The saved source was confirmed through Git at the displayed time. |
| Waiting to sync | New edits are saved locally and waiting for a short pause. |
| Syncing | Git is checking, merging or publishing a saved snapshot. |
| Offline | Online remains selected. Work stays local until the connection returns. |
| On-device | Automatic synchronisation is stopped until you choose Online. |
| Review needed | Overlapping edits need your choice. Recovery copies are kept. |

## Reconnection

The open project groups edits before publishing. It waits for five quiet seconds, with a twenty-second limit during continuous typing and at least fifteen seconds between automatic checks while writing. Remote checks start one minute apart and slow to five minutes when nothing changes. Hidden workspaces and On-device mode stop automatic checks. Sync now checks immediately.

Transient failures retry with increasing delays. Rate-limit responses wait at least five minutes. A failed request does not discard local work or switch the chosen mode. A rejected push never becomes a force push.

Independent changes merge in a private working copy. Changes typed during a request are reconciled before updating the editor. Ambiguous text, deletion or binary changes stop for review. Use Sync now to retry or Review changes to compare both versions.

Restarting remile reuses a pending recovery operation. A fetch checks an uncertain upload before sending it again. See [recovery storage and limits](workspace/overleaf.md#choose-a-mode) for the copy budget, retained records and legacy data policy.

## Local work

Download the project and install the required TeX tools, packages and fonts before travelling. Local PDF compilation and source navigation do not need Overleaf. Different local TeX versions or fonts can produce a different PDF.

## Review notes

Comments and suggestions use a separate web-session connection when you open Review. This exception is independent of Git synchronisation and uses private web interfaces. Acceptance uses a reviewed suggestion ID. Rejection restores source through Git, verifies the restored remote text, then clears only the original suggestion marker. A small local recovery record prevents a retry from restoring the same text twice. Overleaf history can show the Git restoration and a separate accepted-range event. Grouped or moved suggestions still need review in Overleaf. Review has no background refresh timer.

Git updates can move or remove Overleaf comments and tracked changes. Avoid simultaneous Git publishing and sensitive collaborative review. The app does not provide live cursors or presence.

## Existing copies

Existing Git projects and explicit mode choices are retained. Older web-only copies remain on this Mac. Add a Git connection separately and compare any unpublished work before removing the old copy. Legacy recovery journals are retained.

[Overleaf guide](workspace/overleaf.md) · [CLI workflows](cli.md#common-workflows)
