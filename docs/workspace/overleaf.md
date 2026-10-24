# Overleaf

Keep the comfort of a local editor and the connection to your shared project.

## Connect a project

1. Open Overleaf from Home.
2. Add an account and choose the project.
3. Provide its Git token when prompted.

Create a token in **Overleaf → Account settings → Git integration**. Compiling locally also needs a TeX installation.

## Work, then review

In Online mode, saved local changes sync automatically while the project is open. New remote changes wait in **Check changes** for your review.

Resolve conflicts before updating or publishing. Offline mode stops remote work, while your local draft stays editable.

## Choose live editing carefully

Live mode shares existing text edits and pauses Git publication. File changes or overlapping edits can need review. Read the [live sync details](../overleaf-realtime.md) before using it for a shared session.

## Hand a project to an agent

Right-click a project in the Overleaf library or Recently opened and choose **Copy project ID**. Paste it into your request with the research folder to compare. The ID stays the same when the project is renamed or connected on another Mac.

The agent can [read the project through the CLI](../cli.md#overleaf-projects), including unsaved source and PDF build status. An ID identifies the project. It does not grant access or confirm that the local copy is up to date.

## Buttons at a glance

| Button | What it does |
| --- | --- |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/refresh.svg" alt="" width="24" height="24"> **Sync / Check changes** | Inspect remote changes before applying them. |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/chat.svg" alt="" width="24" height="24"> **Comments** | Read project comments and replies. |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/history.svg" alt="" width="24" height="24"> **History** | Open the relevant project or source history. |

[Shared buttons and status marks](../buttons.md)

The editor shares the [LaTeX buttons and build-status marks](latex.md#buttons-at-a-glance).

[Accounts, comments and sync controls](../details/features.md#overleaf)
