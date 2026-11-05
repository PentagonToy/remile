# Online Overleaf synchronisation

Choose Online to synchronise through Overleaf's Git integration. Choose Local to edit and compile on this Mac. The project remembers your choice. New connections start Online.

## Connection states

| State | Meaning |
| --- | --- |
| Editing | Online edits are still being saved on this Mac. |
| Saved | The source is saved on this Mac. Hover for the last remote confirmation. |
| Saved locally · sync delayed | A sync attempt failed. The app keeps the local save and retries. Hover for the reason. |
| Couldn’t save | Saving on this Mac failed. Hover for the error. |
| Unsaved changes | Local edits have not been saved on this Mac yet. |
| Saved locally · offline | Online remains selected. Work stays local until the connection returns. |
| Saved on this Mac | Choose Online to resume synchronisation. |
| Review needed | Sync needs your choice. Recovery copies are kept. |

## Reconnection

The open project queues local changes five seconds after the last edit, or after twenty seconds of continuous typing. Uploads follow this edit schedule. Automatic attempts stay at least fifteen seconds apart and respect retry delays. An unchanged open project checks Overleaf after thirty seconds, then every minute. After applying changes, remile checks again in fifteen seconds. Incoming changes keep checks at that interval for two minutes. Returning to the app brings the next check forward within the same limits. Hidden workspaces and Local mode stop automatic checks. Sync now checks immediately.

Automatic retries use increasing delays. After a rate-limit response, the next automatic attempt waits at least five minutes. If the Mac reconnects, remile brings forward retries for connection failures and keeps any server cooldown. Local work and the selected mode survive a failed request. All pushes use Git's normal fast-forward checks.

Independent changes merge in a private working copy. Changes typed during a request are reconciled before updating the editor. Unique source moves with unchanged content retain the other writer's edits and keep the selected tab. Competing destinations, deletion against editing and ambiguous text or binary changes still stop for review. Further writing or file operations retry recoverable conflicts automatically, keeping request spacing and error backoff. Review changes remains available when a choice is needed.

Overleaf Git can leave an empty folder after its files move or are deleted. Once the files have synced, check the old folder in Overleaf and remove it there if it is empty. [Overleaf Git limitations](https://docs.overleaf.com/integrations-and-add-ons/git-integration-and-github-synchronization/git-integration/advanced-git-operations#known-limitations)

Restarting remile reuses the pending recovery snapshot. If an upload's outcome is uncertain, remile checks Overleaf before sending it again. If another Git process moves the local branch during sync, remile keeps that revision and stops for review. See [recovery copies](workspace/overleaf.md#recovery-copies) for storage limits.

Local autosave continues during typing and network requests, rather than waiting for a quiet period. An ordinary quit saves through the document close flow. After a crash or power loss, the next launch reads the last complete local save and checks any pending upload before repeating it. Input since that save can still be lost if the process or computer stops abruptly.

## Local work

Download the project and install the required TeX tools, packages and fonts before travelling. Local PDF compilation and source navigation do not need Overleaf. Different local TeX versions or fonts can produce a different PDF.

## Review notes

Open Review and choose **Enable review** to fetch comments and suggestions through Overleaf’s private web interfaces. The choice also applies to CLI review requests. Disable access from the Review export menu. Git synchronisation uses a separate connection. Acceptance uses a reviewed suggestion ID. Rejection restores source through Git, verifies the restored remote text, then clears only the original suggestion marker. A small local recovery record prevents a retry from restoring the same text twice. Overleaf history can show the Git restoration and a separate accepted-range event. Grouped or moved suggestions still need review in Overleaf. Review has no background refresh timer.

Git updates can move or remove Overleaf comments and tracked changes. Avoid simultaneous Git publishing and sensitive collaborative review. The app does not provide live cursors or presence.

## Existing copies

Existing Git projects and explicit mode choices are retained. Older web-only copies remain on this Mac. Add a Git connection separately and compare any unpublished work before removing the old copy. Legacy recovery journals are retained.

[Overleaf guide](workspace/overleaf.md) · [CLI workflows](cli.md#common-workflows)
