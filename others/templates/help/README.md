# Hover guidance

`bubble.json` supplies the values consumed by `Sources/Remile/App/HelpBubbleStyle.swift` and `BubbleHelp.swift`. Apply `.bubbleHelp(RemileHints.overleafToken)` to a control to use the same native, anchored popover and accessible help action. Keep the copy to one short sentence or navigation path. Never include credentials in help text.

The delay is 180 ms. The popover uses adaptive app colours, a native arrow, 14 pt system type and 13 pt padding. Animations follow General → Animations and Reduce Motion. Hover tasks are cancelled when the pointer leaves or the control disappears. Keyboard and VoiceOver users can invoke Show help.

`bubble-light.svg` and `bubble-dark.svg` are editable vector examples for reuse and design review. Native popover chrome remains system-rendered. Reuse the JSON and component together. Another platform should map the tokens to its own accessible tooltip or popover. The remile. component and template are MIT-licensed. Apple system symbols and third-party marks retain their own terms.
