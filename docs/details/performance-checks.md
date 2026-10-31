# Performance checks

Measure the operation being changed with a fixed fixture, record the machine and toolchain, and preserve the result alongside the tested source. Do not treat a fast local Git operation as hosted Overleaf latency or a cache limit as the application's total RAM use.

## Local Git sample — 31 October 2026

On an Apple M1 Pro Mac with 16 GB RAM, Xcode's Swift 6.4 toolchain ran the existing synthetic Git benchmarks against temporary local repositories. The observed durations were 0.246 seconds for 20 local Git commands, 0.470 seconds to prepare 20 changed files and 0.071 seconds to resume a recovery fixture with 24 attachments. These are individual local samples, not averages, a version-to-version speedup or a user-facing latency guarantee. The fixtures do not contact Overleaf.

Run the same tests with `REMILE_GIT_BENCHMARK=1 swift test --filter 'OverleafGitSyncTests.*Benchmark'`, using an external scratch directory. The tests verify resulting content as well as reporting time. Run `tools/check_reader_performance.sh /absolute/external/output` for sidebar resizing, thumbnail-cache invalidation and tour timing checks. Those 19 assertions check behaviour rather than establish a whole-app frame-rate benchmark.

## Before making broader claims

Compare identical documents and settings across versions. Record cold and warm search time, peak resident memory and background CPU for a large PDF, a 2,000-document library and concurrent Git collaboration. Such a matched whole-app comparison was not performed in this pass. Keep marketing and release notes within the measured scope.
