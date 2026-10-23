# Reusable artwork and interface templates

This directory contains maintained artwork and the help template used by remile. Runtime artwork is copied into the application bundle. It never depends on this checkout after installation.

| Directory | Contents |
| --- | --- |
| `brand/icons` | Rounded macOS icons and full-bleed variants for hosts that apply a mask |
| `brand/banners` | Original complete Light/Dark banners |
| `brand/wordmarks` | Lettering preserved from the original banner |
| `symbols/providers` | ChatGPT mark used by provider controls |
| `symbols/integrations` | Overleaf leaf used by project controls |
| `symbols/system-symbols.json` | Actual literal SF Symbols names and source locations. Native system artwork is not redistributed |
| `brand/scenes` | Light/Dark lighthouse and Harbour illustrations |
| `motion/airplane` | Light/Dark flight artwork for Work offline transitions |
| `templates/help` | Shared JSON tokens, editable Light/Dark examples and usage instructions for the native help bubble |
| `licences` | Notices for third-party artwork and fixed search words |

`catalogue.json` maps each shipped SVG to its bundle location. Run `tools/catalog_artwork.py` with the host's Python to regenerate the asset and system-symbol catalogues, or pass `--check` to verify them. Variable and composed system-symbol expressions remain defined in source. Bundle names are stable across directory reorganisation.

Apple Intelligence uses native `apple.intelligence`. Manual uses `pencil.tip`. The former reference image and unused `ai-off.svg` have been archived outside the asset library, with their original hashes in the 22 October 2026 task evidence. Do not replace actual system symbols with screenshot copies.

Preserve the wordmark lettering. Use the application’s adaptive slate, paper and gold colours. Templates and original remile. artwork may be reused under the repository MIT licence. The OpenAI mark retains its third-party licence and trademark terms. See `licences/CHATGPT-LICENSE.txt` and `../THIRD_PARTY_NOTICES.md`. Native SF Symbols must be resolved through the target operating system’s APIs.
