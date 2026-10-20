# remile. artwork

Reusable vector artwork lives in `icons/` and `banners/`. The application copies these assets into its bundle, so it does not depend on this checkout at runtime.

- `icons/chatgpt.svg` is the OpenAI mark with a tightly fitted view box. Its path is unchanged. Attribution and licence are in `icons/CHATGPT-LICENSE.txt`.
- Apple Intelligence uses the native `apple.intelligence` system symbol. `icons/references/apple-intelligence-user-reference.png` preserves the supplied visual reference.
- `icons/ai-off.svg` records the manual-writing symbol used for the disabled AI state. All provider controls share a 32 pt target and approximately 20 pt visible artwork.
- `banners/remile_banner_*.svg` preserves the original complete banner. `remile_wordmark_*.svg` and `remile_lighthouse_*.svg` let the app arrange the same artwork in a flexible frame without stretching the lettering.

Baker can reuse the artwork and the provider distinction. A local engine requires its own availability and model-download handling. ChatGPT access uses the official authorised plan connection.
