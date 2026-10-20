# AI and writing assistance

remile. shares its AI controls across PDF questions, library search, Markdown and LaTeX. Apple Intelligence handles local requests. ChatGPT uses the connected account’s eligible plan, with Luna as the initial model when available. Manual disables model assistance while system spelling remains available.

The provider symbol opens a menu for Apple Intelligence, ChatGPT and Manual. A pen represents Manual. A dot on ChatGPT means its connection needs sign-in or unlock. A dot on Apple Intelligence means automatic fallback while the preferred ChatGPT service is unavailable. The preferred ChatGPT choice is retained and becomes active again when the blocking condition clears. Related AI actions are grouped in toolbars and project settings. Native hover hints explain the current state. The User guide uses the same descriptions for edit colours and ChatGPT plan use.

## Plan usage

remile. does not use an API key or bill a separate API account. Eligible requests use the ChatGPT plan or available credits according to the user’s ChatGPT settings. remile. never purchases credits. Plus users share their five-hour allowance across connected apps. OpenAI states that this five-hour limit does not apply to Pro. The daily app ceiling defaults to 100 requests. It is a personal stopping point rather than a guarantee that the ChatGPT allowance covers 100 requests. The local request bar measures only the user’s daily remile. limit, not the remaining account allowance. Official usage and limits remain available through ChatGPT Settings → Usage.

Requests run on explicit user actions. Concurrent inference is serialised, repeated writing alternatives and identical diagnostic fixes are cached, and a returned allowance error pauses further cloud requests. Ordinary questions fall back to the local engine when offline or unavailable. LaTeX repair remains an explicit cloud action with review before applying.

## Context and prompts

Instruction templates are collected under `Sources/Remile/Assistant/Prompts`. Document content is passed separately as untrusted input. Repair proposals still require exact, unique source matches. Source changes invalidate pending proposals, and applying a repair remains undoable and visible through the eye control.

Cloud questions retain up to twelve relevant passages and 64,000 UTF-8 bytes of evidence, with up to eight earlier turns and 20,000 bytes of conversation context. PDF retrieval keeps broader page context, Markdown ranks later blocks against the question, and search reads complete indexed passages for cloud questions. Device requests keep their smaller context. Low, Mid and High retain distinct response budgets. These are resource bounds rather than a claim of equivalence with the ChatGPT application, whose tools and system configuration differ.

The application needs no login item or separate background service. Remote checks run while the project is open. Automatic ChatGPT and Git credential reads never display an authorisation prompt. Unlock connection is an explicit action and waits away from the interface thread. macOS may require authorisation again when an unsigned development build changes identity.

Sources: [OpenAI accounts and usage](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions), [plan usage interface guidance](https://developers.openai.com/siwc/ui-ux-guidelines).

### Saved connections

Locked means remile. could not read its saved ChatGPT connection from macOS Keychain. There is no inactivity timer. The unlocked connection remains in memory for the current process. Restarting the app clears that memory; a development rebuild can also change the app’s signing identity and require macOS approval again. Unlock connection requests access through macOS without removing the saved account. Token renewal is separate from this local lock. Release builds should use a consistent Developer ID signing identity.
