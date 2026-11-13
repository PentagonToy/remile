# Performance checks

Measure the operation being changed with a fixed fixture, record the machine and toolchain, and preserve the result alongside the tested source. Do not treat a fast local Git operation as hosted Overleaf latency or a cache limit as the application's total RAM use.

## Local Git sample — 31 October 2026

On an Apple M1 Pro Mac with 16 GB RAM, Xcode's Swift 6.4 toolchain ran the existing synthetic Git benchmarks against temporary local repositories. The observed durations were 0.246 seconds for 20 local Git commands, 0.470 seconds to prepare 20 changed files and 0.071 seconds to resume a recovery fixture with 24 attachments. These are individual local samples, not averages, a version-to-version speedup or a user-facing latency guarantee. The fixtures do not contact Overleaf.

Run the same tests with `REMILE_GIT_BENCHMARK=1 swift test --filter 'OverleafGitSyncTests.*Benchmark'`, using an external scratch directory. The tests verify resulting content as well as reporting time. Run `tools/check_reader_performance.sh /absolute/external/output` for sidebar resizing, thumbnail-cache invalidation and tour timing checks. Those 19 assertions check behaviour rather than establish a whole-app frame-rate benchmark.

## Writer editing sample — 13 November 2026

An optimised native fixture on an Apple M1 Pro with Xcode Swift 6.4.2 compared the same 56,700-character document across 16 pages with 60 shapes. The two builds differed only in the Writer model and canvas. Across three runs per build, the median per-operation time went from 0.133 to 0.077 ms for caret moves within one style and from 0.497 to 0.420 ms for single-character replacements and pagination. The median peak resident memory across runs changed from 61.7 to 60.8 MiB for caret moves and from 58.0 to 57.6 MiB for replacements. The fixture checks that page and character counts agree and measures native update work outside the full app.

## LaTeX completion sample — 13 November 2026

On the same Mac, eight alternating runs per build queried a 72-file project after warming its index. The median of each run's mean lookup time moved from 0.127 to 0.119 ms. Both builds returned 4,800 suggestions per run, and their peak memory was about 12.5 MiB. The sample measures local completion lookup and excludes the typing debounce and popover.

In a separate Swift fixture, 2,000 single-file edits to a 1,500-file buffer map took a median of 0.693 ms per edit with full change detection and 0.018 ms when the edited file was supplied directly. This isolates the buffer update and change detection from text layout, history and Git sync.

## PDF Ask sample — 13 November 2026

On the same Mac, an optimised native fixture ranked a 90-page synthetic PDF and returned six excerpts. Across five runs per build, median retrieval time went from 0.707 to 0.430 seconds. The ordered passages matched in every run and peak resident memory stayed around 65 MiB. The fixture measures local PDF extraction and passage ranking without the search index or an AI provider.

## Search result navigation sample — 13 November 2026

An optimised Swift fixture used 200 grouped matches across 20 documents. Across seven runs, the median for 6,000 position lookups went from 193 ms to 0.63 ms when reusing the flattened list and comparing path and page directly. The positions agreed. This isolates result navigation and excludes SwiftUI rendering and PDF loading.

## Reference sidebar sample — 13 November 2026

An optimised Swift fixture held 2,000 records across 45 libraries and collections. Across seven runs, the median for 400 reads of both sidebar counts went from 80.9 ms to 0.12 ms, including the initial partition. Both versions returned 1,618 active records and 382 in Trash. This isolates catalogue filtering and excludes SwiftUI rendering and PDF thumbnails.

## Overleaf project picker sample — 13 November 2026

An optimised Swift fixture compared repeated filtering and grouping with reuse of an already prepared catalogue. It used 5,000 projects, 24 tags and 50 connected projects. Across seven runs, the median for 150 reads of unchanged groups went from 127 ms to 0.038 ms after the first preparation. Both versions returned the same number of entries. The sample excludes SwiftUI layout and network requests.

## Before making broader claims

Compare identical documents and settings across versions. Record cold and warm search time, peak resident memory and background CPU for a large PDF, a 2,000-document library and concurrent Git collaboration. Such a matched whole-app comparison was not performed in this pass. Keep marketing and release notes within the measured scope.
