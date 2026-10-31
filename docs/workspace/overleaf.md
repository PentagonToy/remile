# Overleaf

Keep the local editor connected to an Overleaf project through Git. Comments and suggestions have a separate review connection.

## Connect a project

1. Open Overleaf from Home and choose Add project.
2. Add an account label and its Git token.
3. Paste the Overleaf project or Git link and name the local project.

Create a token in **Overleaf → Account settings → Git integration**. Eligible Git access and a local TeX installation are required. The project list shows copies already added on this Mac. Git does not provide an account-wide project catalogue.

## Choose a mode

**Online** saves locally and synchronises through Git while the project is open. It is the default for new connections. Independent remote edits merge automatically. Overlapping edits wait for review. Sync now checks the saved work immediately.

**On-device** stops automatic synchronisation. Editing, local compilation and source navigation remain available. Choose Online when you want to reconnect.

An interrupted Online connection keeps the selected mode and saves work locally. It retries when the connection returns. Repeated failures back off without opening repeated dialogs. A quick return within 45 seconds can reuse the last project and PDF. Its hidden synchronisation timer is stopped.

## Read review notes

Choose Review beside Files for comments and tracked suggestions. Review connects separately and can request sign-in without interrupting Git editing. It uses private web requests, not a collaboration socket. Refresh updates the snapshot. Exports and source-location navigation remain available.

Cards show the author when supplied, the date and the file path. Select the path to visit its source location. Editor line numbers are controlled in **Settings → LaTeX → Line numbers**. Opened project files use the bottom tab bar, with the same behaviour as local LaTeX projects.

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
