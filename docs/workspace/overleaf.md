# Overleaf

Edit and compile a local copy of your Overleaf project. In **Online** mode, remile syncs the source through Git.

## Browse and download projects

1. Open **Overleaf** from Home and sign in to see your account’s projects and tags. Choose a grid or list.
2. Double-click a **Cloud only** card to download and open it. Right-click and choose **Download for Offline Use** to download without opening.
3. If prompted, create a Git token in **Overleaf → Account settings → Git integration**. To connect a project by URL, choose **+ → Add by link**.

**On this Mac** means the source is available offline. Downloads and source sync require Overleaf Git access. Install TeX locally to compile.

## Free up disk space

Close projects before removing their local copies. Choose **Free Up Space…** in the library toolbar to select one or more copies, or right-click a card to start with it selected.

remile verifies each copy against Overleaf and keeps any project with unsynced or pending work. Eligible copies move to Trash with their local Git recovery history. The results show how many moved and explain why any selected copies stayed. The projects remain available in Overleaf. Empty Trash to reclaim the space.

## Choose a mode

- **Online** syncs automatically while the project is open. **Saved** means your work is on this Mac. Hover for the last remote confirmation.
- **Local** pauses sync. Before travelling, download the project and install its required TeX packages and fonts. Choose **Online** to resume.

Use **Sync now** when you need an immediate check. Independent changes merge automatically. If remile needs your input, choose **Review changes**. [Sync timing and recovery](../overleaf-realtime.md)

The [file tree](latex.md#find-your-way) and [source editor](latex.md#find-and-complete) work as in local LaTeX. Drop a folder into **Files** to add its contents. Empty folders stay on this Mac until they contain a file.

Both modes compile on this Mac. If the project builds on Overleaf's website but remile reports a missing package, check your [local TeX setup](latex.md#when-a-build-needs-attention).

### Recovery copies

remile keeps one pending recovery copy per project and up to three managed references after a successful sync. A 256 MiB preflight budget pauses new preparation when space is insufficient and preserves pending work. Existing Git history and older unlabelled recovery copies have separate lifetimes.

## Read review notes

Choose **Review → Enable review** for comments and tracked suggestions. Review uses Overleaf’s private web interfaces in a separate web session. Use **Refresh** for a new snapshot or the export menu to disable access. The same setting applies to CLI review requests.

Select a card’s file path to jump to the source. Once sync is confirmed and the location still matches, use ✓ or × to act on a single suggestion. Accepting updates its review status. Rejecting restores the text through Git, then clears the original suggestion marker after verification. Handle moved or grouped suggestions in Overleaf. Git updates can move or remove review markers.

In **Ask**, use **Attach Overleaf feedback** to prepare notes and source excerpts for a question. You choose when to send it.

## Hand a project to an agent

Right-click a project marked **On this Mac** and choose **Copy project ID**. The [CLI](../cli.md#overleaf-projects) reads open editor buffers, source hashes and the sync state last seen by remile.

## Buttons at a glance

| Button | What it does |
| --- | --- |
| **Sync now** | Checks Overleaf and reconciles source. Approve Keychain access if macOS asks. |
| **Review changes** | Compares overlapping source changes. |
| **Connection options** | Opens projects, edits the Git token or reveals recovery copies. |

[Workspace overview](../workspace-layout.md)
