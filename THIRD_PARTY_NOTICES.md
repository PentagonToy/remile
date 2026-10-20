# Third-party notices

The root [MIT licence](LICENSE) covers remile. source code. It does not replace third-party copyright notices, platform licences, service terms or trademark rights.

## Incorporated material

| Material | Origin | Licence and changes |
| --- | --- | --- |
| ChatGPT icon, `others/icons/chatgpt.svg` | [OpenCode provider icon](https://github.com/anomalyco/opencode/blob/dev/packages/ui/src/assets/icons/provider/openai.svg) | MIT, copyright © 2025 opencode. The SVG path matches the inspected upstream asset. The view box is fitted to the existing path, and the app renders it in its gold accent colour. |

The complete upstream MIT notice is retained in [CHATGPT-LICENSE.txt](others/icons/CHATGPT-LICENSE.txt) and copied into the application bundle. OpenAI owns the ChatGPT name and mark. The asset’s software licence does not grant ownership of the mark. See [OpenAI’s brand guidelines](https://openai.com/brand/).

## Platform components and external tools

The app uses macOS frameworks and system libraries, including AppKit, SwiftUI, PDFKit, WebKit, Vision, Foundation Models, SQLite and zlib. `Package.swift` declares no external Swift package dependencies. System frameworks and [SF Symbols](https://developer.apple.com/sf-symbols/) remain subject to Apple’s applicable terms. remile. does not relicense or redistribute the macOS SDK or an SF Symbols font.

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

The confirmed incorporated asset is listed above. The recorded references and the current native source were inspected for copied material. A bounded comparison against 2,525 reference source files found no matching eight-line blocks of at least 200 whitespace-normalised characters. This comparison cannot establish independent authorship or detect translated adaptations. It is not permission to copy GPL or AGPL source into the MIT app. Any future incorporation must be reviewed and attributed under its actual licence.
