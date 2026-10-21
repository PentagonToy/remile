# AI and writing

Select Apple Intelligence, ChatGPT or Manual in AI settings or the toolbar provider menu. Apple Intelligence runs on this Mac. ChatGPT uses an eligible connected account; Luna is the initial model when available. Manual disables model assistance and retains system spelling.

## Connections and usage

Connect ChatGPT through its sign-in flow. Credentials stay in macOS Keychain. A connection dot indicates that sign-in or unlock needs attention. Unlock connection requests Keychain access; restarting clears the in-memory unlocked connection. App signing changes can require macOS approval again.

Automatic fallback optionally uses Apple Intelligence when ChatGPT is unavailable. With fallback off, requests report the unavailable service. The preferred provider remains selected.

ChatGPT requests use the account’s available plan or credits under its settings. remile. uses no API key and does not purchase credits. The daily app limit defaults to 100 requests and measures remile. activity, not the account’s remaining allowance. Check ChatGPT Settings → Usage for account usage. See OpenAI’s [account guidance](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions) and [usage interface guidance](https://developers.openai.com/siwc/ui-ux-guidelines).

Inference requests are serialised. Repeated writing suggestions use bounded session caches. An allowance error pauses cloud requests. LaTeX repair requires an explicit request and review before applying.

## Writing

Select up to 2,000 characters of prose and choose Proofread with the selected provider. Review the replacement, apply it or dismiss it. Code, maths and TeX commands are excluded. Double-click an underlined word for corrections; a selected word also offers alternatives. Undo restores the source.

Automatic spelling and grammar underlines use macOS. Optional grey inline completions use Apple Intelligence: Tab accepts and Escape dismisses them. Switching documents clears a pending completion. AI settings provides one Writing suggestions switch, with individual options under its disclosure.

LaTeX diagnostics offer Suggest fix. The proposal must match the unchanged source before it can be applied. Compilation guidance can also send bounded error summaries and package lookup results to ChatGPT on request, without source buffers. It displays advice and optional commands for review.

## Document questions

Ask sends the question and selected document evidence to the chosen provider. Cloud evidence is limited to 64,000 UTF-8 bytes, with up to eight earlier turns and 20,000 bytes of conversation context. PDFs up to 96 pages include all extracted text when it fits; otherwise relevant excerpts are selected. Longer indexed PDFs can reuse matching file-scoped library passages and neighbouring pages. Missing or stale indexes use direct retrieval. Device requests use smaller context budgets.

Explicit selections and relevant visible pages take priority. Source links return to the passage. Evidence is extracted text; it does not cover every page image or establish that an answer or formula is correct. Low, Mid and High select response budgets.

Prompt templates live in `Sources/Remile/Assistant/Prompts`. Document content is passed separately as untrusted input. Source edits require exact matches and remain undoable. remile. requests do not create ChatGPT conversation history.

## Work offline

Work offline is an app-wide switch in General settings and the document toolbar. It pauses ChatGPT, Overleaf, update checks and TeX package lookups, cancelling registered network work. Local editing, compilation, keyword search and available Apple Intelligence remain usable. Turning it off retains provider and per-project Online preferences.

This switch controls remile.’s network requests. macOS services, cloud storage providers and already transmitted data remain outside its scope.
