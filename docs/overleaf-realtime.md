# Live Overleaf synchronisation

Open a project in Live to work with Overleaf while staying in remile. Private keeps a local draft for review before publication. Your choice is remembered for that project.

## Connection status

| Status | What to do |
| --- | --- |
| Connecting | Wait for the project to join. |
| Pending changes | Keep working while remile sends your edits. |
| Awaiting confirmation | Wait for Overleaf to confirm the update. |
| Confirmed | Your current source changes are confirmed. |
| Reconnecting | Keep your draft open while the connection recovers. |
| Paused | Click the status to reconnect or review the reported issue. |
| Review required | Compare the local and remote versions before continuing. |

Source confirmation and PDF freshness are separate. Compile after editing to refresh the PDF.

## Keep your draft safe

Brief connection failures retry automatically. Pending edits stay available. Overlapping changes and uncertain file replacements pause for review rather than silently choosing a version.

Resolve the highlighted difference, then use the action offered by the review screen. If you prefer to work separately, switch to Private and publish after reviewing your changes. Git publication stays paused while Live is active.

## Files and recovery

Live reconciles text and project files. File recovery copies appear through the paused status when a replacement needs attention. Review those copies before deleting them.

Work offline stops online operations. Returning online allows reconnection. Leaving a project stops its file checks. One recent project may remain briefly available for a quick return.

## Limits

Overleaf account permissions and service changes can interrupt a connection. Large source archives or frequently changing file trees may need more time. Conflicts, account restrictions and repeated file changes need your attention. Private remains available as a separate review workflow.

[Overleaf guide](workspace/overleaf.md) · [CLI workflows](cli.md#common-workflows)
