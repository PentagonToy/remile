# Overleaf

Keep the comfort of a local editor and the connection to your shared project.

## Connect a project

1. Open Overleaf from Home.
2. Choose an account, or use **Manage…** to connect one.
3. Press **+** beside a project to add it to your local library.

Create a token in **Overleaf → Account settings → Git integration**. Compiling locally also needs a TeX installation.

## Start in Live

Projects start in Live when online. Text edits sync with Overleaf while you work. remile remembers an explicit switch to Private or Local on this Mac. Work offline pauses remote access.

After a brief connection loss, Live keeps your edits locally and reconnects automatically. Conflicting edits or account problems still need your attention. You can choose Private or Local while a connection is starting.

## Work, then review

Private is the review path when you need to reconcile changes deliberately. A Live connection problem does not silently switch modes or start a second Git writer.

In Private mode, saved local changes sync through Git while the project is open. New remote changes wait in **Check changes** for your review.

Resolve conflicts before updating or publishing. After review, remile keeps your active source, cursor and scroll position when that file still exists. Offline mode stops remote work, while your local draft stays editable.

Use `\cite{` in the source editor for local citation suggestions. [Read the citation hints →](../reference.md#read-citation-hints)

## Read review notes

Choose **Review** beside Files to read Overleaf comments and tracked additions or deletions. Click a file and line to reveal its source. Refresh after remote changes. Navigation waits if the local source differs from the review snapshot. Accept or reject a single change after Live sync is confirmed. Grouped changes with a shared server ID remain in Overleaf. Reject restores the source through the same Live connection. Replies and comment resolution remain in Overleaf. Export includes every comment and change, including resolved threads, as Markdown or JSON.

The speech bubble opens **Ask**, with review actions just above the message field. **Review manuscript** reuses the saved manuscript criteria. **Attach Overleaf feedback** prepares Overleaf notes and source excerpts for a question without replacing text you have already typed. Questions use the assistant selected in remile. Preparing feedback does not send it to a model.

Export all review notes as Markdown or JSON, or choose **Review package with sources…** for a ZIP. The package includes text sources, IDs, hashes and the exact review snapshots needed to interpret changed local files. Figures and PDFs are omitted. An agent can fetch the review through [the project-ID CLI](../cli.md#overleaf-projects).

## Choose a mode

Live mode shares existing text edits and pauses Git publication. A quick return within 45 seconds reuses the most recent Live project and PDF. One project is retained, with its hidden file-check timer stopped. File changes or overlapping edits can need review. Read the [live sync details](../overleaf-realtime.md) before using it for a shared session.

## Hand a project to an agent

Right-click a project in the Overleaf library or Recently opened and choose **Copy project ID**. Paste it into your request with the research folder to compare. The ID stays the same when the project is renamed or connected on another Mac.

The agent can [read the project through the CLI](../cli.md#overleaf-projects), including unsaved source and PDF build status. An ID identifies the project. It does not grant access or confirm that the local copy is up to date.

## Buttons at a glance

| Button | What it does |
| --- | --- |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/refresh.svg" alt="" width="24" height="24"> **Sync / Check changes** | Inspect remote changes before applying them. |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/chat.svg" alt="" width="24" height="24"> **Ask** | Ask about the project using your chosen assistant. |
| <img class="remile-guide-symbol" src="../../others/symbols/guide/history.svg" alt="" width="24" height="24"> **History** | Open the relevant project or source history. |

[Shared buttons and status marks](../buttons.md)

The editor shares the [LaTeX buttons and build-status marks](latex.md#buttons-at-a-glance).

[Accounts, comments and sync controls](../details/features.md#overleaf)

## Choose how to sign in

Use your Overleaf email and password in the connection window, or choose **Other ways…** for the official web screen. Google, ORCID, IEEE and institutional sign-in remain there. Extra verification continues on Overleaf. Email and password fields provide AutoFill hints to macOS. **Apple Passwords** opens the Passwords app to choose your saved Overleaf login. Your password is not saved by remile.

Login providers may restrict embedded browsers. If a provider refuses this window, use another supported Overleaf login method.

## Manage accounts

Choose **Accounts → Manage accounts…** in the library to rename or connect an account. The same window opens from **Manage…** when adding projects. Set the plan, sign in or save a Git token there. **Remove account…** asks before deleting the account’s local projects, history and unpublished edits. Projects on Overleaf are kept. Close the account’s open projects first.
