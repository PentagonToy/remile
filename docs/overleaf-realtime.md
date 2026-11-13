# Online Overleaf synchronisation

**Online** saves your work on this Mac and syncs it with Overleaf through Git. **Local** pauses sync so you can keep editing and compiling offline.

| If you see | What to do |
| --- | --- |
| **Saved** | Keep working. Hover to see when Overleaf last confirmed a sync. |
| **Saved locally · offline** or **sync delayed** | Keep editing. Online retries when the connection returns or the retry delay ends. |
| **Couldn’t save** | Hover over the message to see why the local save failed. |
| **Review needed** | Open **Review changes**. remile keeps recovery copies when it cannot merge safely. |

## When changes sync

Online queues edits after five seconds of quiet or twenty seconds of continuous typing. Automatic requests stay at least fifteen seconds apart. Open, idle projects check for changes every thirty to sixty seconds. Recent remote edits keep that interval at fifteen seconds for two minutes. Hidden workspaces and Local mode pause automatic checks. Use **Sync now** for an immediate check.

Connection failures trigger retries. Rate limits pause automatic attempts for at least five minutes. Reconnecting brings network retries forward while respecting the server cooldown.

## If work is interrupted

remile merges independent edits and clear file moves. Overlapping edits, an edit to a deleted file or a competing move can require review. If a file move leaves an empty folder in Overleaf, remove it there after sync. [Overleaf Git limitations](https://docs.overleaf.com/integrations-and-add-ons/git-integration-and-github-synchronization/git-integration/advanced-git-operations#known-limitations)

A normal quit saves through the document close flow. After a crash or power loss, remile reopens the last complete local save and checks Overleaf before retrying an uncertain upload. Keystrokes after that save may be lost. [Recovery copies and storage limits](workspace/overleaf.md#recovery-copies)

If you have an older web-only copy, add a Git connection and compare any unpublished work before removing the old copy.

[Overleaf guide](workspace/overleaf.md) · [CLI workflows](cli.md#common-workflows)
