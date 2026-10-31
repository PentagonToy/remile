# Test map

Run the standard suite with a full Xcode installation and an external scratch directory:

```sh
swift test --build-system native --scratch-path /absolute/path/to/remile-tests --jobs 2
```

The Overleaf tests follow the current Git implementation:

| Suite | Purpose |
| --- | --- |
| `OverleafGitSyncTests` | Concurrent edits, interrupted uploads, recovery, file installation and scheduling |
| `OverleafSourceTests` | Unicode edits, bounded merging, file validation and exclusive writer locks |
| `OverleafReviewTests` | Comment archives, source anchors, exports, cancellation, dates and author privacy |
| `OverleafReviewAccessTests` | Default-off review access, revocation, pre-network guards and native notice layout |
| `OverleafProjectCatalogueTests` | Exact web read scope, optional tags and project grouping |
| `OverleafOnlineBarTests` | Save states, controls and light/dark layout |
| `OverleafConnectionNoticeTests` | First-use connection consent |

Local Git benchmarks are opt-in through `REMILE_GIT_BENCHMARK=1`. They use temporary repositories and do not contact Overleaf. Hosted collaboration and account authentication require separate manual verification.

Other `*Checks` directories retain focused integration fixtures not yet covered by the standard suite. They are not all duplicates. Run their matching `tools/check_*.sh` entry points when changing those areas. `tools/check_overleaf_safety.sh` combines Git (including review and source safety), commands, login and titlebar checks without running review twice. It does not replace `swift test`.

macOS CI also runs the existing Overleaf command routing, login-form and titlebar scripts. These fixtures need no live account. Keep those checks until their distinct behaviour is covered in the standard suite.

The retired socket coordinator, packet, acknowledgement and OT replay checks have been removed with their unused implementation. Current merge and writer safety cases live in `OverleafSourceTests`. Preserve data-loss, privacy and permission cases when consolidating checks.

`NativeConnectionTests` preserves the former native-connection script fixtures as standard tests: signed identity, callback and stream failures, exact edits, collections and catalogue metadata. `check_native_connections.sh` now delegates to that suite.
