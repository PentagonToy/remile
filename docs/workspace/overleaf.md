# Overleaf

Keep the local editor connected to an Overleaf project through Git. Comments and suggestions have a separate review connection.

## Connect a project

1. Open Overleaf from Home and choose Add project.
2. Add an account label and its Git token.
3. Sign in to choose a project, or expand **Add by link** and paste its Overleaf or Git link.

Create a token in **Overleaf → Account settings → Git integration**. Eligible Git access and a local TeX installation are required. The chooser reads your account’s project list through a separate web session when opened or manually refreshed. Projects start in collapsible tag groups, with untagged projects last. A project with several tags appears in each matching group. Search matches project and tag names locally, including projects in collapsed groups. Return selects the first result. The selected project remains named beside Add project. Manual refresh keeps the current list and selection while checking for changes. Tag colours are fetched alongside the list. Project contents are not downloaded until selected. The list is discarded when the chooser closes. Selected projects connect through Git. Git tokens alone cannot list projects.

## Choose a mode

**Online** saves locally and synchronises through Git while the project is open. It is the default for new connections. Independent remote edits merge automatically. Overlapping edits wait for review. If a collaborator uploads during your sync, remile fetches the new history and tries one fresh merge. It never force-pushes. Sync now checks the saved work immediately.

After returning to the project or syncing changes, remile checks for remote edits every fifteen seconds for two minutes. Quiet projects then slow to one to five minutes between checks. Rapid window changes do not trigger repeated requests, and connection errors keep their retry delay.

**On-device** stops automatic synchronisation. Editing, local compilation and source navigation remain available. Choose Online when you want to reconnect.

An interrupted Online connection keeps the selected mode and saves work locally. It retries when the connection returns. Repeated failures back off without opening repeated dialogs. A quick return within 45 seconds can reuse the last project and PDF. Its hidden synchronisation timer is stopped.

Interrupted Git sync reuses one pending recovery copy per project, including after restarting remile. It checks the server before repeating an uncertain upload and preserves edits made since the interruption. Changed Git history or overlapping remote work can still require review.

Recovery receipts contain Git object IDs, not copies of document text. Completed sync removes its temporary copy and keeps three managed recovery references. Before staging, remile checks a 256 MiB recovery budget with room for the current project. When space is insufficient, it pauses new preparation and keeps pending work. Existing Git history and older, unlabelled recovery copies are outside automatic expiry. Recovery references do not impose a hard size limit on Git's object database.

Identical attachments are read once per recovery attempt and share memory. This does not create a persistent content cache. File and project size limits still count every path, including duplicate attachments.

## Read review notes

Choose Review beside Files for comments and tracked suggestions. Review connects separately and can request sign-in without interrupting Git editing. It uses private web requests, not a collaboration socket. Refresh updates the snapshot. Exports and source-location navigation remain available.

Cards show the author when supplied, the date and the file path. Select the path to visit its source location. Editor line numbers are controlled in **Settings → LaTeX → Line numbers**. Opened project files use the bottom tab bar, with the same behaviour as local LaTeX projects.

The selected review card has a quiet outline. Disabled acceptance and rejection buttons explain the next required step in their tooltip. The connection bar distinguishes unsaved edits from work saved on this Mac and confirmed synchronisation.

Use ✓ to accept or × to reject a single suggestion after synchronisation is confirmed and its location still matches. Acceptance updates review metadata through the web connection. Rejection restores the source through Git, verifies it and clears the original suggestion marker. Overleaf history can record this as a source edit and a separate accepted-range event. Moved or grouped suggestions may need to be handled in Overleaf. Git updates can remove or displace comments and tracked changes.

The speech bubble opens Ask. Review manuscript uses your saved criteria. Attach Overleaf feedback prepares review notes and source excerpts for a question. Preparing feedback does not send it to a model.

## Hand a project to an agent

Right-click a saved project and choose Copy project ID. The [CLI](../cli.md#overleaf-projects) reads open editor buffers, source hashes and locally observed sync status. Reading does not fetch, publish or establish the latest server version. The compatibility `live` field now reports `transport: git`.

## Buttons at a glance

| Button | What it does |
| --- | --- |
| Online / On-device | Choose whether this project synchronises. |
| Sync now | Check and reconcile saved source through Git. |
| Review changes | Compare overlapping source changes. |
| Connection options | Open projects, edit the Git token or reveal recovery copies. |
| Review | Read comments and suggestions through the separate review connection. |

[Sync details](../overleaf-realtime.md) · [Workspace overview](../workspace-layout.md)
