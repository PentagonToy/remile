# Voice and wording

remile. should feel calm, warm and clear. Help the reader act, then let them return to their work.

## Lead with what matters

- Start with the action or result. Use words people recognise.
- Give each sentence one job. Prefer a full stop to a semicolon.
- Do not use semicolons in UX copy or explanatory prose. Preserve them in code, protocol data and quoted source material.
- Cut the explanation before shrinking the text or truncating it.
- Use familiar verbs. Avoid implementation details unless they change a decision.
- Keep conditions that affect cost, privacy, saving or destructive actions.
- Use British English. Keep ordinary Markdown paragraphs on one physical line.

## Keep the interface quiet

- Aim for one short sentence in hints and settings descriptions.
- Give tour steps one action and at most two short supporting sentences. Aim for 25 words or fewer.
- Let titles name the purpose. Let buttons name the action.
- Put optional detail in wrapping help or documentation. Never clip a necessary instruction.
- Do not repeat a button label or a nearby status in its explanation.
- Keep poetry in the banner, empty states and waiting moments. Keep operational guidance direct.
- Preserve “Across time, a few words find you here.” and the established lighthouse voice. Do not decorate every control with a metaphor.

## Hover help and persistent status

Use `remileHelp` for SwiftUI hover hints and `toolTip` for AppKit controls. Both use native macOS tooltips. Do not open a custom popover on hover. Keep click-open popovers for settings, actions and details that need user attention.

Show ongoing account restrictions in the workspace footer using the adaptive gold accent. Name the restricted feature. Base the notice on the connected account's saved plan and access settings, not the project title or source contents. A saved plan is a user preference, not verified subscription data.

## Examples

| Prefer | Avoid |
| --- | --- |
| Connect a project. Local edits sync automatically. Remote changes wait for review. | Online sends your local edits automatically, while new remote changes wait for review. |
| No separate API bill from remile. | No API key is required, which means there are no additional bills. |
| Pause online services. Keep working locally. | Disable networking to continue working in a local environment. |
| Allow more time for large projects. | Increase the compilation time limit to accommodate larger projects. |

The billing line describes remile. It does not promise free ChatGPT usage. Keep the account condition nearby: “Your ChatGPT plan and credit settings apply.”

## Review before shipping

Read the copy as a returning user. Can they find the action at a glance? Remove repeated context, split joined clauses and check that the remaining words are accurate. Verify Git and Live sync wording separately. Technical docs may need detail, but each sentence should still earn its place.


## Scroll surfaces

Reserve at least the shared 18 pt trailing gutter between app-owned scrolling cards and the scrollbar. Apply it outside the card background and inside the scroll viewport. Keep wider established spacing. Native document canvases retain their own layout. Attachment markers use the adaptive gold accent, reserving warning colours for conditions that need attention.
