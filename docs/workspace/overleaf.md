# Overleaf

Keep the local editor connected to an Overleaf project through Git. Comments and suggestions have a separate review connection.

Overleaf shares the [file tree](latex.md#find-your-way) and [source editor](latex.md#find-and-complete) with local LaTeX. Rename items directly in **Files**. File paths and commands complete from the local copy. Drop folders into **Files** to add nested sources and assets. Online mode syncs supported files through Git. Empty folders stay on this Mac until they contain a file.

## Connect a project

1. Open Overleaf from Home and choose Add project.
2. Add an account label and its Git token.
3. Sign in to choose a project, or expand **Add by link** and paste its Overleaf or Git link.

Create a token in **Overleaf → Account settings → Git integration**. Eligible Git access and a local TeX installation are required. The chooser reads your account’s project list through a separate web session when opened or manually refreshed. Projects start in collapsible tag groups, with untagged projects last. A project with several tags appears in each matching group. Search matches project and tag names locally, including projects in collapsed groups. Return selects the first result. The selected project remains named beside Add project. Manual refresh keeps the current list and selection while checking for changes. Tag colours are fetched alongside the list. Project contents are not downloaded until selected. The list is discarded when the chooser closes. Selected projects connect through Git. Git tokens alone cannot list projects.

## Choose a mode

**Online** saves on this Mac and syncs through Git while the project is open. New connections start Online. **Local** pauses sync and keeps editing, compilation and source navigation available. Choose **Online** to resume.

**Saved** means the current source is on this Mac. Hover over it to see the last remote confirmation. [Connection states and retry timing](../overleaf-realtime.md) explain how local saves and remote checks relate.

remile merges independent text edits and unambiguous source moves. Changes found while confirming an upload can be applied in the same attempt, together with later local typing. Overlapping edits or a changed local Git branch can require review. Choose **Sync now** for an immediate check.

### Recovery copies

remile keeps one pending recovery copy per project and checks Overleaf before repeating an uncertain upload. A successful sync clears the pending copy and retains up to three managed recovery references. Before staging, remile checks a 256 MiB budget for recovery storage and the current project. It pauses new preparation when space is insufficient and keeps pending work. Existing Git history and older unlabelled recovery copies have their own lifetimes.

## Read review notes

Choose **Review** beside Files, then **Enable review** to fetch comments and tracked suggestions. Review uses a separate web session and may ask you to sign in. Refresh updates the snapshot. The choice applies to CLI review requests too. Use the Review export menu to disable access.

Cards show the author when supplied, the date and the file path. Select the path to visit its source location. Editor line numbers are controlled in **Settings → LaTeX → Line numbers**. Opened project files use the bottom tab bar, with the same behaviour as local LaTeX projects.

The selected review card has a quiet outline. Disabled acceptance and rejection buttons explain the next required step in their tooltip. The connection bar distinguishes unsaved edits from work saved on this Mac and confirmed synchronisation.

Use ✓ to accept or × to reject a single suggestion after synchronisation is confirmed and its location still matches. Acceptance updates review metadata through the web connection. Rejection restores the source through Git, verifies it and clears the original suggestion marker. Overleaf history can record this as a source edit and a separate accepted-range event. Moved or grouped suggestions may need to be handled in Overleaf. Git updates can remove or displace comments and tracked changes.

The speech bubble opens Ask. Review manuscript uses your saved criteria. Attach Overleaf feedback prepares review notes and source excerpts for a question. Preparing feedback does not send it to a model.

## Hand a project to an agent

Right-click a saved project and choose Copy project ID. The [CLI](../cli.md#overleaf-projects) reads open editor buffers, source hashes and locally observed sync status. Reading does not fetch, publish or establish the latest server version. The compatibility `live` field now reports `transport: git`.

## Buttons at a glance

| Button | What it does |
| --- | --- |
| Online / Local | Choose whether this project synchronises. |
| Sync now | Check and reconcile saved source through Git. Approve Keychain access if macOS asks. |
| Review changes | Compare overlapping source changes. |
| Connection options | Open projects, edit the Git token or reveal recovery copies. |
| Review | Read comments and suggestions through the separate review connection. |

[Sync details](../overleaf-realtime.md) · [Workspace overview](../workspace-layout.md)
