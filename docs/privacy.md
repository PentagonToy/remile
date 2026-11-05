# Your files and privacy

Your documents stay in the folders you choose. Reading, editing and standard local search need no AI account.

## On your Mac

Reference stores its catalogue and copied PDFs together. Its default folder is `~/Library/Application Support/local.remile.app/Reference`. Settings → Storage can move Reference and this Mac’s search data into one folder. Each Mac uses a separate search database. macOS manages preferences in `~/Library/Preferences/local.remile.app.plist`.

Presets carry supported preferences. They exclude credentials, accounts, document paths and the library location. Search indexes and device caches stay local. Downloaded Markdown images can remain in `~/Library/Caches/local.remile.app/MarkdownImages`, with a 256 MiB HTTP cache capacity. The cache respects source response policies and is not copied into the document or shared Reference storage.

Find, replace and TeX completion use the local editor and project data. Closing Find cancels pending work and releases its result snapshot. No search term or command prefix is sent to a service by these tools.

## When you connect

Questions and selected document context are sent to the AI provider when you submit a request. ChatGPT suggestions use your connected account and its limits. Read [AI and writing](assistant.md) for context boundaries and provider controls.

Overleaf synchronisation sends project changes through the configured connection. Update checks contact GitHub. Work offline pauses remile’s online requests.

Reference can send a detected DOI or arXiv identifier, or a title you choose to look up, to public bibliographic services. Link lookup contacts the source you provide and may follow advertised PDF links. These lookups keep the contents of your local PDFs on your Mac. Citation suggestions compare your preceding sentence with locally stored titles and abstracts on your Mac.

ScienceDirect sign-in takes place on the publisher or institution’s website. By default, remile uses a temporary browser profile. If you choose **Remember sign-in on this Mac**, WebKit keeps the session in a separate profile on this Mac. remile does not store your password or read your browser’s cookies. Choose **More actions → Forget sign-in** on the ScienceDirect page to clear the saved profile.

A library inside Dropbox or iCloud Drive is handled by that provider. Keep it downloaded for offline reading, and edit on one Mac at a time after synchronisation finishes. See [Reference storage](reference.md#storage-and-other-macs).

## Work offline

The airplane button pauses remile's online services. Local documents and standard search remain available. This setting controls remile's requests. It does not stop macOS or another app's cloud synchronisation.

## This website

This site uses local fonts and adds no analytics, advertising or contact forms. GitHub Pages hosts the site under [GitHub's privacy policy](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).

Search keeps its index and reusable cache on this Mac. Keyword search does not upload document content. Removing a folder from Library removes its indexed text and clears the ranking cache.
