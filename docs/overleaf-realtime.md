# Online Overleaf synchronisation

Online keeps a local project connected through Overleaf's Git integration. On-device keeps editing and compilation on this Mac without synchronising. The project remembers your choice. New connections start Online.

## Connection states

| State | Meaning |
| --- | --- |
| Editing | Online edits are still being saved on this Mac. |
| Saved | The source is saved on this Mac. Hover for the last remote confirmation. |
| Saved locally · retrying | A sync attempt failed. The app keeps the local save and retries. Hover for the reason. |
| Couldn’t save | Saving on this Mac failed. Hover for the error. |
| Unsaved changes | On-device edits have not been saved on this Mac yet. |
| Saved locally · offline | Online remains selected. Work stays local until the connection returns. |
| Saved on this Mac | On-device mode keeps work local until you choose Online. |
| Review needed | Overlapping edits need your choice. Recovery copies are kept. |

## Reconnection

The open project groups Git changes for five seconds after the last edit, or up to twenty seconds during continuous typing. Automatic attempts stay at least fifteen seconds apart and respect retry delays. For two minutes after returning to the project or syncing changes, remote checks run fifteen seconds apart. They then slow from one to five minutes when nothing changes. Returning to the app brings the next check forward, while keeping minimum spacing and error backoff. Hidden workspaces and On-device mode stop automatic checks. Sync now checks immediately.

Transient failures retry with increasing delays. Rate-limit responses wait at least five minutes. A failed request does not discard local work or switch the chosen mode. A rejected push never becomes a force push.

Independent changes merge in a private working copy. Changes typed during a request are reconciled before updating the editor. Unique source moves with unchanged content retain the other writer's edits and keep the selected tab. Competing destinations, deletion against editing and ambiguous text or binary changes still stop for review. Further writing or file operations retry recoverable conflicts automatically, keeping request spacing and error backoff. Review changes remains available when a choice is needed.

Restarting remile reuses a pending recovery operation. A fetch checks an uncertain upload before sending it again. See [recovery storage and limits](workspace/overleaf.md#choose-a-mode) for the copy budget, retained records and legacy data policy.

Local autosave continues during typing and network requests, rather than waiting for a quiet period. An ordinary quit saves through the document close flow. After a crash or power loss, the next launch reads the last complete local save and checks any pending upload before repeating it. Input since that save can still be lost if the process or computer stops abruptly.

## Local work

Download the project and install the required TeX tools, packages and fonts before travelling. Local PDF compilation and source navigation do not need Overleaf. Different local TeX versions or fonts can produce a different PDF.

## Review notes

Open Review and choose **Enable review** to fetch comments and suggestions through Overleaf’s private web interfaces. The choice also applies to CLI review requests. Disable access from the Review export menu. Git synchronisation uses a separate connection. Acceptance uses a reviewed suggestion ID. Rejection restores source through Git, verifies the restored remote text, then clears only the original suggestion marker. A small local recovery record prevents a retry from restoring the same text twice. Overleaf history can show the Git restoration and a separate accepted-range event. Grouped or moved suggestions still need review in Overleaf. Review has no background refresh timer.

Git updates can move or remove Overleaf comments and tracked changes. Avoid simultaneous Git publishing and sensitive collaborative review. The app does not provide live cursors or presence.

## Existing copies

Existing Git projects and explicit mode choices are retained. Older web-only copies remain on this Mac. Add a Git connection separately and compare any unpublished work before removing the old copy. Legacy recovery journals are retained.

[Overleaf guide](workspace/overleaf.md) · [CLI workflows](cli.md#common-workflows)
