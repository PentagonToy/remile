# Performance checks

Measure the operation you change with the same fixture and settings before and after. Record the source commit, Mac model, toolchain and whether the run started cold or warm. Keep dated results with the tested source and fixtures.

| Area | Check |
| --- | --- |
| Overleaf Git | Set `REMILE_GIT_BENCHMARK=1` and run `swift test --filter 'OverleafGitSyncTests.*Benchmark'` with an external scratch directory. The fixtures measure local commands, preparation and recovery without contacting Overleaf. |
| PDF reader | Run `tools/check_reader_performance.sh /absolute/external/output` for sidebar resizing, thumbnail invalidation and tour timing. Test repeated opens and closes with the same PDF when changing reader lifetime. |
| Search and libraries | Compare cold and warm search with the same index and documents. Keep the result order fixed when measuring navigation. Test both Overleaf layouts with the same catalogue and window widths. |

For a whole-app comparison, also record peak memory and background CPU. Measure hosted Overleaf sync separately from local Git. Check that results, reading position and saved edits agree before comparing speed.
