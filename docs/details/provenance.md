# Source provenance review

This is a bounded engineering check dated 31 October 2026, not a complete copyright clearance or a legal certification. The current application licence remains MIT. No specific incorporated GPL or AGPL implementation was identified by this check. Unconfirmed historic asset permissions remain separate.

## Scope and method

Current Swift source was compared with the local `overleaf-textarea-master` snapshot (17 JavaScript/TypeScript source and test files (including module and JSX/TSX extensions)) and `ayakaleaf-pro-server-pro` snapshot (4,436 source and test files, including module sources). Generated, dependency and build folders were excluded, as were reference files over 1 MB. The comparison removed C-style comments and looked for exact 40-token windows containing at least 12 identifier tokens. It found no matching pairs. This lexical method can miss renamed, translated, reordered, shorter or otherwise adapted code. A zero-match result does not prove independent authorship.

A focused manual comparison examined `EditorSpellcheck.swift` against the textarea filter helper and the Overleaf project-list/read-path handling against the server reference. The former uses native spelling exclusions rather than the reference's ordered text-replacement pipeline. The latter shares protocol field names and routes. These observations describe the inspected implementation, not ownership of every expression. Git source sync and the absence of a vendored server or browser extension are distinct from the rights attached to any copied material.

The incorporated-material inventory in [third-party notices](../../THIRD_PARTY_NOTICES.md) covers the stopword data, provider artwork and optional renderer dependencies. No old binaries or archived source versions were cleared by this comparison. In particular, the Overleaf logo in 0.2.2 retains unresolved asset and trademark permission questions. Version 0.2.3 is the recommended replacement and no longer bundles that logo.

## Handling a later finding

Record the upstream URL, revision or snapshot hash, original file, local destination, copied or adapted portion, licence and retained notices. Review the terms for the actual combination before redistribution. Remove or replace the material where appropriate, or adopt compatible distribution terms with the required notices and source obligations. A root switch to AGPL would not by itself resolve asset permissions, missing attribution or connected-service terms. Earlier MIT grants and other contributors' rights also need to be respected.

See the [GNU licence FAQ](https://www.gnu.org/licenses/gpl-faq.html) and [Open Source Guides](https://opensource.guide/legal/). Record the limits of each check rather than treating a similarity score as permission.
