# Extensions

Available in remile. 0.2.3.

Enable an extension with its card’s switch, then click the card to choose sources. Disabling it preserves imported references and PDFs.

## reMarkable

### Register a device

1. Enable developer mode and SSH access on the device. Developer mode can erase the device when enabled. For Wi-Fi, enable SSH over WLAN and use the device’s Wi-Fi address.
2. Connect in Terminal first. Verify the SSH host key against the device’s fingerprint before saving it. For USB with one device, use `ssh root@10.11.99.1`.
3. In remile, open **Extensions → reMarkable**. Choose **… → Add device…**, enter the same address or SSH alias and the device’s SSH password, then choose **Connect**. Each device’s connection is saved in this Mac’s Keychain. Pick a saved device from the same menu.
4. Select folders and choose **Add to Reference**. Parent folders include descendants. **Unfiled** includes documents outside folders.

### Use multiple devices over USB

If both devices use `10.11.99.1`, give them separate aliases in `~/.ssh/config`:

```sshconfig
Host rmp rmp-move
    HostName 10.11.99.1
    User root

Host rmp
    HostKeyAlias rmp

Host rmp-move
    HostKeyAlias rmp-move
```

Plug in one device at a time. Verify each device in Terminal with its own alias, for example `ssh rmp`. Add `rmp` and `rmp-move` separately in remile. An existing saved connection appears as **Previous connection**.

If a connection times out, wake the selected device and check the USB cable or Wi-Fi address. If the host key differs, confirm that the plugged-in device matches the alias and verify its fingerprint in Terminal. If the password changes, choose **Add device…** and enter the same alias with the new password.

When your devices share documents through reMarkable sync, remile uses their document IDs to update the same Reference entries. Missing items stay in Reference. If both copies report a modification time, an older device copy cannot replace a newer imported copy.

The extension reads device metadata and selected document files over SSH. It does not write to the device, alter its settings or use the reMarkable cloud API. Refresh and Update library run on request, without a background connection or polling.

Tools are downloaded into remile’s Application Support folder on Apple silicon Macs. No administrator access or separate Python setup is needed. Existing working tools are reused. Failed or cancelled setup preserves previous tools and documents. [Versions, licences and download verification →](../THIRD_PARTY_NOTICES.md#optional-remarkable-connection-tools)

Turning reMarkable off deletes its app-managed tools after confirmation. Re-enabling it requires another download. Imported references, PDFs and saved Keychain credentials remain. Manually selected external helpers are never deleted. **Connection tools → Existing tools** lets you choose an existing renderer. macOS may request Keychain approval after the app’s signing identity changes.

You can also export a PDF from the official reMarkable app and open it in remile. SSH access does not change the licences of the ink renderer or imported documents. Existing working renderers are reused. New tool installations contain only the four ink-renderer packages listed in the lock.

Right-click reMarkable in Reference and choose Update library to receive new documents, subfolders and changed handwriting. Choose folders changes the tracked range. Disconnect folders stops updates and keeps existing references. Older imports can still update known documents until folders are chosen. Updates run on request, without background polling.

Local fields and keys take priority. Changed source PDFs replace unedited imported versions. Local PDF edits stay beside the new version. Missing remote documents and local Trash are not restored by updates.

Thesis and Dissertation map to `mastersthesis` and `phdthesis`. Explicit degree statements on a PDF’s first three pages can identify them locally. University uses the BibTeX `school` field.

New notes use `note_Name_YYYYMMDD`, with numeric collision suffixes. PDFs with a verified DOI, arXiv ID or one exact public title match adopt the paper type and key rule. Title lookup sends the title to public metadata services, never the PDF or handwriting. Uncertain items remain Note. Manual and locked keys stay unchanged. [PDF sharing and linked notes →](reference.md#connected-notes-and-pdf-storage)

Unmarked PDFs retain the original file when their page order is unchanged. Unmarked pages in mixed documents retain their original page boxes. Pages with handwriting keep the device canvas. Paper Pro / Move handwriting rendering is experimental. Highlight colours may be approximated as yellow. Some transforms, ink formats and notebook templates are unsupported. Check imported PDFs before relying on their placement or colours.

Device documents are never uploaded, changed or deleted. Downloads are limited to 128 MB, expanded files to 256 MB, rendering to 500 pages and managed PDFs to 200 MB. Download limits do not guarantee fixed peak memory use. Temporary downloads are removed after import or cancellation.

## Zotero

Keep Zotero running and enable Allow other applications on this computer to communicate with Zotero in Settings → Advanced. remile checks the connection automatically. Use Check again if needed. No address, API key or plugin is required.

Choose libraries or collections and select Add to Reference. Collections include descendants. Copies appear under Zotero in Reference and can be edited or given new citation keys. New entries retain a supplied Zotero citation key or item key, with suffixes for collisions. Repeating Add to Reference creates independent copies.

Right-click an imported library and choose Update library. Existing fields, types and keys take priority, missing fields are filled, and new items and subcollections are added. Stable Zotero identities survive key changes and duplicate merging. Local PDF edits are retained beside newer source versions. Remote removals never delete local references.

Only locally downloaded PDFs are copied. Unavailable files are reported, without requesting remote downloads or changing Zotero. Each source is saved separately, so completed sources remain after a later failure or cancellation. Imported copies remain usable with Zotero closed.

More → Use as connected citation sources offers direct, read-only citations without importing records or PDFs. These sources are labelled Zotero in the citation picker and autocomplete, and need Zotero for fresh metadata. Existing project bibliographies keep their details and keys when Zotero changes or is disabled.
