# Third-party notices

The root [MIT licence](LICENSE) covers remile. source code. It does not replace third-party copyright notices, platform licences, service terms or trademark rights.

## Incorporated material

| Material | Origin | Licence and changes |
| --- | --- | --- |
| Fixed English stopword list, `SearchLexicon.swift` | scikit-learn 1.9.1 `ENGLISH_STOP_WORDS` | BSD-3-Clause, copyright © 2007–2026 the scikit-learn developers. Additional question scaffolding words are local. No Python or scikit-learn runtime is shipped. Full notice: [SEARCH-WORDS.txt](others/licences/SEARCH-WORDS.txt), also copied into the app. |
| ChatGPT icon, `others/symbols/providers/chatgpt.svg` | [OpenCode provider icon](https://github.com/anomalyco/opencode/blob/dev/packages/ui/src/assets/icons/provider/openai.svg) | MIT, copyright © 2025 opencode. The SVG path matches the inspected upstream asset. The view box is fitted to the existing path, and the app renders it in black in light appearance and white in dark appearance. |

The complete upstream MIT notice is retained in [CHATGPT-LICENSE.txt](others/licences/CHATGPT-LICENSE.txt) and copied into the application bundle. OpenAI owns the ChatGPT name and mark. The asset’s software licence does not grant ownership of the mark. See [OpenAI’s brand guidelines](https://openai.com/brand/). The mark uses a monochrome appearance without the app’s gold tint. Retaining the MIT notice and using monochrome rendering do not settle all trademark permission or placement requirements.

## Earlier releases

Release 0.2.2 includes `overleaf-mark.svg`, whose paths match the inspected `overleaf/overleaf` repository asset at `services/web/public/overleaf-logo.svg` (AGPL-3.0 repository). Its applicable asset licence and separate trademark permission remain unconfirmed. Current development source replaces it with the native `leaf` SF Symbol and no longer bundles that SVG. This source change does not replace earlier release binaries. [Official logo policy](https://www.overleaf.com/for/partners/logos).

## Platform components and external tools

The app uses macOS frameworks and system libraries, including AppKit, SwiftUI, PDFKit, WebKit, Vision, Foundation Models, SQLite and zlib. `Package.swift` declares no external Swift package dependencies. System frameworks and [SF Symbols](https://developer.apple.com/sf-symbols/) remain subject to Apple’s applicable terms. remile. does not relicense or redistribute the macOS SDK or an SF Symbols font.

The Apple Intelligence indicator uses the operating system’s `apple.intelligence` SF Symbol through SwiftUI, rather than a bundled Apple logo file. Its SF Symbols usage restriction permits referring to Apple Intelligence and prohibits modifying the symbol. remile uses it for the Foundation Models provider and on-device fallback, not as its app icon or brand. Apple Intelligence is a trademark of Apple Inc. [Xcode and Apple SDKs Agreement, section 2.10](https://www.apple.com/legal/sla/docs/xcode.pdf) and [SF Symbols guidance](https://developer.apple.com/design/human-interface-guidelines/sf-symbols) apply. Native rendering options do not grant broader branding or marketing rights.

Git and TeX tools are invoked as external executables. The app packager does not bundle Git, TeX Live, MacTeX, latexmk, BibTeX, Biber, SyncTeX, epstopdf or Ghostscript. Those separately installed programs retain their own licences. ChatGPT and Overleaf are connected services rather than incorporated source packages.

## Development references

The inspected reference corpus informed interaction design and protocol compatibility. These references are not declared package dependencies or vendored source trees in remile.:

| Reference | Licence of inspected copy | Use recorded during development |
| --- | --- | --- |
| [Overleaf Desktop](https://github.com/eric-xw/Overleaf-Desktop) | MIT | Native Git workflow and account-storage design. |
| [overleaf-comments-export](https://github.com/Mangluu/overleaf-comments-export) | MIT | Comment endpoints and export data fields. |
| `ayakaleaf-pro-server-pro`, an Overleaf server reference | AGPL-3.0 | Project-list response fields and separation of live presence from source operations. |
| `overleaf-textarea-master` | GPL-3.0 | Source-aware prose filtering and editor behaviour. |
| [autoresearcherUI](https://github.com/Fchaubard/autoresearcherui) | MIT | Explicit review and observable progress. |

Development references are not redistribution permissions. Earlier bounded source comparisons were not a complete provenance audit and do not establish independent authorship, including for artwork or translated adaptations. Any incorporated GPL or AGPL material needs review under its actual licence.

## Optional reMarkable connection tools

The remile-authored transport invokes the Mac’s `/usr/bin/ssh` and reads selected document files from the user’s device. No OpenSSH or reMarkable device software is bundled. reMarkable documents SSH access through [Developer Mode](https://developer.remarkable.com/documentation/developer-mode). This is not an official remile integration or provider endorsement. The app does not enable developer mode, change SSH settings, install device software or write device files. It does not use reMarkable cloud tokens or cloud APIs.

Local handwriting conversion uses `rmc` 0.3.0 (MIT) and `rmscene` 0.6.1 (MIT), with Click 8.5.0 (BSD-3-Clause) and packaging 23.2 (Apache-2.0 OR BSD-2-Clause). Their unchanged notices are in [remarkable-tools notices](others/licences/remarkable-tools/README.md) and copied into the application’s Licences folder. No rMsync source is bundled.

After a separate installation action, remile downloads app-private Python 3.12.16 from [python-build-standalone](https://github.com/astral-sh/python-build-standalone) and the four pinned wheels from PyPI. [runtime.json](others/extensions/remarkable/runtime.json) records versions, origins, sizes, SHA-256 hashes and SPDX licence identifiers. The Python distribution and installed wheels retain their own licence files. Neither Python nor those wheels are included in remile release packages. Reusing an earlier private runtime preserves its original dependency notices. The current lock contains no cloud connector or HTTP client dependency.

SSH passwords are stored in a non-synchronising, device-only macOS Keychain item. Host verification remains enabled. These safeguards do not replace the owner’s authorisation or the rights attached to the documents. Developer mode has its own reset, security and support implications described by reMarkable.

## Connected services and user documents

Zotero integration is remile-authored Swift code using Zotero’s [documented local API](https://www.zotero.org/support/dev/web_api/v3/local_api). No Zotero application, SDK, citation-style bundle or translators are shipped. Zotero, reMarkable, Overleaf, OpenAI and ChatGPT names and marks belong to their respective owners. remile. is independent and is not presented as endorsed by those providers.

Software licences do not grant access to accounts, permission to use private APIs or rights to redistribute imported papers. Connected services retain their own terms. In particular, Overleaf’s [Acceptable Use Policy](https://www.overleaf.com/legal) restricts unsupported interfaces and automated access. Current development source uses the documented Git integration for source synchronisation and removes the collaboration socket. Comments and suggestions retain a separate, narrowly scoped private web-interface exception. That exception remains subject to provider terms and permission review. Earlier release binaries retain their previous behaviour. The development reMarkable connection uses device SSH access, not cloud account access. SSH access does not grant permission to redistribute device software or imported documents. A user’s opt-in is not provider approval.

Imported PDFs, annotations, metadata and project templates retain their existing rights. Local copying, storage sharing, citation-key changes or metadata edits do not transfer copyright or make those materials MIT-licensed.
