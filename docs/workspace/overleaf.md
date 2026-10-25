# Overleaf

Keep the comfort of a local editor and the connection to your shared project.

## Connect a project

1. Open Overleaf from Home.
2. Choose an account, or use **Manage…** to connect one.
3. Press **+** beside a project to add it to your local library.

Create a token in **Overleaf → Account settings → Git integration**. Compiling locally also needs a TeX installation.

## Work, then review

In Online mode, saved local changes sync automatically while the project is open. New remote changes wait in **Check changes** for your review.

Resolve conflicts before updating or publishing. Offline mode stops remote work, while your local draft stays editable.

Use `\cite{` in the source editor for local citation suggestions. [Read the citation hints →](../reference.md#read-citation-hints)

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

## Choose how to sign in

Use your Overleaf email and password in the connection window, or choose **Other ways…** for the official web screen. Google, ORCID, IEEE and institutional sign-in remain there. Extra verification continues on Overleaf. Email and password fields provide AutoFill hints to macOS. **Apple Passwords** opens the Passwords app to choose your saved Overleaf login. Your password is not saved by remile.

Login providers may restrict embedded browsers. If a provider refuses this window, use another supported Overleaf login method.

## Manage accounts

Choose **Accounts → Manage accounts…** in the library to rename or connect an account. The same window opens from **Manage…** when adding projects. Set the plan, sign in or save a Git token there. **Remove account…** asks before deleting the account’s local projects, history and unpublished edits. Projects on Overleaf are kept. Close the account’s open projects first.
