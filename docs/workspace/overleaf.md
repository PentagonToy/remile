# Overleaf

Keep the local editor connected to an Overleaf project through Git. Comments and suggestions have a separate review connection.

The [LaTeX editor](latex.md#find-and-complete) is shared with local projects. File paths, project commands, and known commands from declared packages complete from the local copy. Drop folders into Files to add nested sources and assets. Online mode sends supported files through the usual Git sync. Empty folders stay on this Mac until they contain a file.

## Connect a project

1. Open Overleaf from Home and choose Add project.
2. Add an account label and its Git token.
3. Sign in to choose a project, or expand **Add by link** and paste its Overleaf or Git link.

Create a token in **Overleaf → Account settings → Git integration**. Eligible Git access and a local TeX installation are required. The chooser reads your account’s project list through a separate web session when opened or manually refreshed. Projects start in collapsible tag groups, with untagged projects last. A project with several tags appears in each matching group. Search matches project and tag names locally, including projects in collapsed groups. Return selects the first result. The selected project remains named beside Add project. Manual refresh keeps the current list and selection while checking for changes. Tag colours are fetched alongside the list. Project contents are not downloaded until selected. The list is discarded when the chooser closes. Selected projects connect through Git. Git tokens alone cannot list projects.

## Choose a mode

**Online** saves locally and synchronises through Git while the project is open. It is the default for new connections. Independent remote edits merge automatically. Independent edits within one paragraph can also merge when unique word anchors separate them. When one person continues an unfinished last line and another appends a separate single content line, the continuation comes first and both are kept. Small unambiguous character edits and a longer version of the same appended text can merge automatically. Competing continuations, reordered blocks and other ambiguous or overlapping edits wait for review. Unambiguous source moves retain edits and the selected tab. Further writing or file operations automatically retry recoverable conflicts using the existing request spacing and backoff. Storage and Git history problems still need attention. If a collaborator uploads during your sync, remile fetches the new history and tries one fresh merge. If the confirmation fetch already contains newer work on top of an accepted upload, remile installs that confirmed version in the same attempt and reconciles newer local typing. It does not wait for another polling interval or send a second upload for that acknowledgement. Recovery records advance before installation, and unchanged attachments share their existing memory. It never force-pushes. Sync now is an optional immediate check. Normal writing does not need it.

The connection bar shows **Saved** when the current source is saved on this Mac. Local autosave continues during typing, network requests and offline work without waiting for a quiet period. Automatic transmission and remote checks continue separately without repeatedly changing the saved label. The last remote confirmation remains in hover help and CLI diagnostics. Save failures, offline work, retry and review states remain visible.

After returning to the project or syncing changes, remile checks for remote edits every fifteen seconds for two minutes. Quiet projects then slow to one to five minutes between checks. Typing reuses the scheduled wake-up rather than creating a task for each keystroke. Rapid window changes do not trigger repeated requests, and connection errors keep their retry delay.

**On-device** stops automatic synchronisation. Editing, local compilation and source navigation remain available. Choose Online when you want to reconnect.

An interrupted Online connection keeps the selected mode and saves work locally. It retries when the connection returns. Repeated failures back off without opening repeated dialogs. A quick return within 45 seconds can reuse the last project and PDF. Its hidden synchronisation timer is stopped.

Interrupted Git sync reuses one pending recovery copy per project, including after restarting remile. It checks the server before repeating an uncertain upload and preserves edits made since the interruption. Changed Git history or overlapping remote work can still require review.

Recovery receipts contain Git object IDs, not copies of document text. Completed sync removes its temporary copy and keeps three managed recovery references. Before staging, remile checks a 256 MiB recovery budget with room for the current project. When space is insufficient, it pauses new preparation and keeps pending work. Existing Git history and older, unlabelled recovery copies are outside automatic expiry. Recovery references do not impose a hard size limit on Git's object database.

Identical attachments are read once per recovery attempt and share memory. This does not create a persistent content cache. File and project size limits still count every path, including duplicate attachments.

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
| Online / On-device | Choose whether this project synchronises. |
| Sync now | Check and reconcile saved source through Git. Approve Keychain access if macOS asks. |
| Review changes | Compare overlapping source changes. |
| Connection options | Open projects, edit the Git token or reveal recovery copies. |
| Review | Read comments and suggestions through the separate review connection. |

[Sync details](../overleaf-realtime.md) · [Workspace overview](../workspace-layout.md)
