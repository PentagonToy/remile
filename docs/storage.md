# Presets and storage

Keep your working preferences familiar, wherever you sit down.

## Presets

In **Settings → Storage**, choose **Save preset**. Give the JSON file a name and keep it locally or in a synced folder.

On another Mac, choose **Load preset** and review the import. Appearance, editing, search, citation and panel preferences travel with it. Reopen a workspace to apply saved panel widths.

Accounts, credentials, document paths and the library location stay local. A preset transfers preferences when loaded. It does not synchronise them automatically.

## Choose locations

**Settings → Storage → Locations** shows two paths. Folder changes take effect when you next open remile.

- **Storage folder** holds search indexes and Overleaf edit marks. **Move storage…** creates `remile-storage` in the chosen parent folder. Each Mac keeps its own search index and writes its own edit marks.
- **Reference folder** holds the library catalogue and managed PDFs. **Move library…** creates `remile-reference` in the chosen parent folder and verifies the copy. Previous files remain available.

## Use the library on another Mac

Move the **Reference folder** into Dropbox or iCloud Drive and let it finish syncing. Download the library on the other Mac, then choose **Reference folder → Change… → Open library…** and restart remile.

Reference opens read only. To edit, turn off **Reference read only** on one Mac after sync finishes. Simultaneous Reference edits are not merged automatically.

## Use Overleaf edit marks on another Mac

Move the **Storage folder** into Dropbox or iCloud Drive. On the other Mac, choose **Storage folder → Change… → Open storage…** and open the same folder. After the folder syncs, remile loads marks when you open the source or return to its window. It matches the Overleaf project and relative file path. The Overleaf website receives the usual source updates.

## External drives

Keep the drive connected while using remile. If it is unavailable, reconnect it. remile does not silently create replacement storage. Keep cloud storage downloaded for offline access.

[Storage details](details/reference.md#storage-and-other-macs) · [Your files and privacy](privacy.md)
