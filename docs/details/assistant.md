# AI and writing

Choose Manual, Apple Intelligence or ChatGPT in AI settings or the toolbar. Apple Intelligence runs on this Mac. ChatGPT uses an eligible connected account. Luna is the initial model when available. Manual disables model assistance and retains system spelling.

## Connections and usage

Connect ChatGPT through its sign-in flow. Credentials stay in macOS Keychain. A connection dot indicates that sign-in or unlock needs attention. Unlock connection requests Keychain access. Restarting clears the in-memory unlocked connection. App signing changes can require macOS approval again.

Automatic fallback optionally uses Apple Intelligence when ChatGPT is unavailable. With fallback off, requests report the unavailable service. The preferred provider remains selected.

No separate API bill from remile. Your ChatGPT plan and credit settings apply. remile. does not purchase credits. The daily app limit defaults to 100 requests and measures remile. activity, not the account’s remaining allowance. Check ChatGPT Settings → Usage for account usage. See OpenAI’s [account guidance](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions) and [usage interface guidance](https://developers.openai.com/siwc/ui-ux-guidelines).

Inference requests are serialised. Repeated writing suggestions use bounded session caches. An allowance error pauses cloud requests. LaTeX repair requires an explicit request and review before applying.

## Writing

Select up to 2,000 characters of prose and choose Proofread with the selected provider. Review the replacement, apply it or dismiss it. Code, maths and TeX commands are excluded. Select a word and right-click for macOS spelling corrections. Undo restores the source.

Automatic spelling and grammar underlines use macOS. Optional grey inline completions use Apple Intelligence: Tab accepts and Escape dismisses them. Switching documents clears a pending completion. AI settings provides one Writing suggestions switch, with individual options under its disclosure.

LaTeX diagnostics offer Suggest fix. The proposal must match the unchanged source before it can be applied. Compilation guidance can also send bounded error summaries and package lookup results to ChatGPT on request, without source buffers. It displays advice and optional commands for review.

## Document questions

Ask sends the question and selected document evidence to the chosen provider. Cloud evidence is limited to 64,000 UTF-8 bytes, with up to eight earlier turns and 20,000 bytes of conversation context. PDFs up to 96 pages include all extracted text when it fits. Otherwise relevant excerpts are selected. Longer indexed PDFs can reuse matching file-scoped library passages and neighbouring pages. Missing or stale indexes use direct retrieval. Device requests use smaller context budgets.

Explicit selections and relevant visible pages take priority. Source links return to the passage. Evidence is extracted text. It does not cover every page image or establish that an answer or formula is correct. Low, Mid and High select response budgets.

Prompt templates live in `Sources/Remile/Assistant/Prompts`. Document content is passed separately as untrusted input. Source edits require exact matches and remain undoable. remile. requests do not create ChatGPT conversation history.

## Work offline

Work offline is an app-wide switch in General settings and the document toolbar. It pauses ChatGPT, Overleaf, update checks and TeX package lookups, cancelling registered network work. Local editing, compilation, keyword search and available Apple Intelligence remain usable. Turning it off retains provider and per-project Online preferences.

This switch controls remile.’s network requests. macOS services, cloud storage providers and already transmitted data remain outside its scope.


LaTeX diagnostics put document structure and dependency failures before ordinary source errors, unresolved references and layout warnings. Equally ranked items retain compiler order. A visibly missing backslash before `documentclass` in the main preamble receives a source-linked check-first entry after a failed build. This is a rule-based candidate, not a general proof of causality. All compiler diagnostics remain available and Terminal preserves the raw log.

LaTeX repair requests include the selected diagnostic, the leading cause candidates, the earliest compiler errors and a bounded main-file preamble. When there is an earlier structural failure, the editable excerpt follows that failure. The prompt asks for evidence before a minimal repair and prohibits replacing custom macros merely to suppress symptoms. If evidence is insufficient, the explanation can be shown without an applicable edit. Suggestions are invalidated when source buffers, the main file or the build log change. No extra model call is made for ordering or context preparation.


PDF-to-LaTeX navigation first uses SyncTeX. A double-click adds a bounded PDF text hint at the actual clicked character without consuming PDFKit's selection gesture. A background comparison checks at most 16,000 UTF-16 source units near the reported line. It normalises words and skips command names while retaining source offsets. A unique strong context match selects the word in the editor, making its sentence visible. Weak, repeated or non-text matches retain the original line jump. This adds no model call, OCR, background scan or extra SyncTeX process. Source/build identity checks remain in place.
