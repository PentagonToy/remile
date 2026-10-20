# Follow-up work

This checkpoint is a working reader/editor prototype, not a finished release. Deerstalker has been built and installed locally. The abandoned Baker connection has been removed; a separate app-neutral Baker adapter is outside this reader.

## Current priority: Home and library search

- The explicitly requested 19 October release build is installed at `/Applications/Deerstalker.app`; native Home and Low/Mid/High Settings were observed. Verify File → Home, file picking/drop, recent documents, PDF Ask/source disclosure/navigation and editing/save behaviour in the actual app. Offscreen renders and session checks are not a substitute for those interactions.
- Convert now handles mixed images, supported Word documents and rendered Markdown with previews. Validate actual picker/drop/preview/save interactions and broader Word layout fidelity. Markdown Convert now supports tables/local images/common TeX notation; broaden complex layout and equation fixtures and bring the richer renderer to the reader. Common OMML, single-section first/even/default headers/footers, PAGE/NUMPAGES and supported inline artwork/previews now work. Full TeX/Word fidelity, multiple sections and arbitrary Office drawings remain pending. Compress now has native Color/Grayscale, three quality presets, size comparison and progress. Validate live picker/drop/save/cancel and broader PDF fidelity, especially unsupported forms/replies and large-file memory.
- The dedicated Search window now uses PDF covers/Markdown artwork, compact page/section rows, original previews and visible transient highlights. Validate installed-app selection, keyboard navigation, resizing, rotated/cropped PDF geometry and explicit Open; Markdown Open still starts in its reader without a section-navigation request. Evaluate ranking and responsiveness on a representative corpus before claiming search quality.
- Library management, on-device Explore query planning and vocabulary-based spelling suggestions now run in source. Broaden metaphor/synonym/typo evaluation beyond the controlled fixtures, measure candidate-budget limits on large scientific corpora and verify real UI cancellation/reopen behaviour. This is query expansion, not dense semantic indexing.
- The PDF reader and Search now share the on-device message-bubble Ask panel. Validate the installed reader toolbar/composer, collapsed source expansion, individual source clicks, repeated-source refocusing, document replacement, save/revert and cancellation. Response detail now persists as Low/Mid/High (default Mid); broaden factual-grounding and longer-answer context-budget checks. Broaden reader passage retrieval and factual-grounding checks; it currently uses extracted text and lightweight lexical matching, without OCR or dense semantic retrieval.
- Search saves selected PDF highlights in the fixed Okabe–Ito palette with immediate coordinated writes and one-step Undo. Validate real selection/toolbar/close/reopen interactions, other-app file coordination, reply-heavy documents, rotated/multicolumn text and large-file memory; saved Markdown highlights remain pending.
- Optional Apple Intelligence Ask now produces cited answers from bounded PDF/Markdown result passages on an available on-device system model. Broaden factual-grounding, language, unavailable-model, context-limit, cancellation and actual panel interaction checks; numeric citation validation does not verify factual entailment.
- Add automatic file watching and per-document indexing errors. Current refresh is manual, uses modification time/size/resource identity and skips unchanged successful files.
- Evaluate OCR for pages without extracted text, Korean segmentation, scientific symbols, memory and responsiveness on large corpora. Existing tests cover separated Korean terms, not morphological or substring matching.

## Interface review

- Exercise Convert from an empty drop area through queued files, successful/failed previews and saving; the primary action changes with the current step.
- Check visible zoom percentages, +/− and Fit across PDF/Markdown readers and search previews, including native shortcuts and resizing. Verify narrow-window toolbar layout and selected-text retention.
- Check General/Ask settings navigation, default Markdown zoom and the explicit Clear History confirmation. Existing appearance, response-detail and retention preferences must remain intact.

## Reader and comments

- Exercise dirty tracking, save/revert, standard undo menus and close/reopen in the installed DocumentGroup application.
- Verify parent/reply anchoring, selected-comment navigation and draft retention across actual UI interactions. Retain standard PDF reply references across repeated saves and other viewers.
- Broaden annotation and encrypted/restricted-document fixtures. Acrobat displayed the tested replies as one conversation; PDF Expert 3.11 hid them in its UI while preserving their underlying links after rewriting the generated fixture.
- Complete Markdown tables, images, mathematics and relative assets; measure editor/preview responsiveness on large documents.

## Search and performance

- Persistent lexical PDF-page/Markdown-section indexing and bounded proximity reranking are now in source. Evaluate its quality and performance before optional local semantic search as described in [search-models.md](search-models.md).
- Package a tested on-demand embedding runtime before exposing model-download settings. Evaluate Qwen3-Embedding-0.6B MLX 4-bit first; pin revisions and hashes, support cancellation/repair/removal, and rebuild embeddings when model/chunking contracts change.
- Measure actual peak memory and latency on representative English/Korean scientific PDFs. Weight-file sizes and upstream throughput claims are not local memory/performance measurements.
- Compare matched-document idle/scroll/search memory with Acrobat and the reference readers; confirm that idle reading keeps no OCR or embedding worker resident.
