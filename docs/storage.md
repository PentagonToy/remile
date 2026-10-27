# Presets and storage

Keep your working preferences familiar, wherever you sit down.

## Presets

In **Settings → Storage**, choose **Save preset**. Give the JSON file a name and keep it locally or in a synced folder.

On another Mac, choose **Load preset** and review the import. Appearance, editing, search, citation and panel preferences travel with it. Reopen a workspace to apply saved panel widths.

Accounts, credentials, document paths and the library location stay local. A preset transfers preferences when loaded. It does not synchronise them automatically.

## Choose one storage folder

In **Settings → Storage → Change → Move storage**, choose a parent folder. remile creates `remile-storage` and applies the move when you next open the app.

Reference records, attachments and this Mac's search index move together. Prepared search caches are retained when available. Original PDFs outside Reference stay where they are. The previous storage remains available for recovery.

## Use the library on another Mac

1. Move storage into Dropbox or iCloud Drive and let syncing finish.
2. Download the complete `remile-storage` folder on the other Mac.
3. Choose **Storage → Change → Open storage**, then restart remile.

Reference opens read only. To edit, turn off Read only on one Mac after sync finishes. Simultaneous Reference edits are not merged automatically.

Each Mac has its own search database inside the same storage folder. Search folders and their access permissions remain specific to that Mac. Do not open another Mac's database directly.

## External drives

Keep the drive connected while using remile. If it is unavailable, reconnect it. remile does not silently create replacement storage. Keep cloud storage downloaded for offline access.

## Preferences

macOS keeps preferences in `~/Library/Preferences`. Presets transfer supported preferences without transferring storage paths or machine identity. **Locations** shows the Reference and search paths.

[Storage details](details/reference.md#storage-and-other-macs) · [Your files and privacy](privacy.md)
