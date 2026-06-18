# Quill QA Test Matrix

## Scope

Validate the system-wide selection flow:

1. Select text in another app.
2. Wait at least 500 ms.
3. Verify floating sparkles icon behavior.
4. Open prompt popover.
5. Run the selected action.
6. Verify editable text is replaced, or read-only text shows `ResultPanel`.

Safari/WebKit `AXSelectedText == nil` is an expected Phase 1 limitation and should not be filed as a bug unless the app crashes or leaves stale UI visible.

## Prompt Coverage

Editable prompts:

| Prompt | Expected handling |
| --- | --- |
| 更精簡 | Replace selected editable text with concise rewrite |
| 更正式 | Replace selected editable text with formal rewrite |
| 修正文法 | Replace selected editable text with corrected text |
| 翻譯成繁體中文 | Replace selected editable text with Traditional Chinese translation |
| 翻譯成英文 | Replace selected editable text with English translation |

Read-only prompts:

| Prompt | Expected handling |
| --- | --- |
| 摘要重點 | Show concise bullet summary in ResultPanel |
| 解釋這段話 | Show plain-language explanation in ResultPanel |
| 翻譯成繁體中文 | Show Traditional Chinese translation in ResultPanel |
| 列出 action items | Show extracted action items in ResultPanel |

## Core App Matrix

| ID | App type | Text length | Setup steps | Expected result | Pass/fail criteria |
| --- | --- | --- | --- | --- | --- |
| TE-01 | TextEdit native editable | `< 3` chars | Open editable TextEdit doc, type `Hi`, select all text, wait 500 ms | Floating icon does not appear | Pass if no icon/popover appears after 500 ms |
| TE-02 | TextEdit native editable | `3-10` chars | Type `hello`, select all text, wait 500 ms | Floating icon appears near selection | Pass if icon appears and hides after deselect |
| TE-03 | TextEdit native editable | Long paragraph | Type a paragraph, select it, wait 500 ms, run each editable prompt | AI result replaces selected text | Pass if selected text is replaced and no ResultPanel appears |
| NO-01 | Notes native editable | `< 3` chars | Create/focus note, type `OK`, select all text, wait 500 ms | Floating icon does not appear | Pass if no icon/popover appears after 500 ms |
| NO-02 | Notes native editable | `3-10` chars | Type `meeting`, select all text, wait 500 ms | Floating icon appears | Pass if icon appears and prompt list opens on click |
| NO-03 | Notes native editable | Long paragraph | Type a paragraph, select it, wait 500 ms, run each editable prompt | AI result replaces selected note text | Pass if replacement happens in Notes, not in Quill |
| SF-01 | Safari WebKit/read-only | `3-10` chars | Open a page, select visible text, wait 500 ms | Phase 1 expected: icon may not appear because `AXSelectedText` can be nil | Pass if no crash/stale icon; do not mark missing icon as bug |
| SF-02 | Safari WebKit/read-only | Long paragraph | Select page text, wait 500 ms | Phase 1 expected limitation | Pass if app remains stable; if icon appears, selected read-only action should show ResultPanel |
| PV-01 | Preview PDF read-only | `3-10` chars | Open PDF, select short text, wait 500 ms | Floating icon appears if Preview exposes `AXSelectedText`; prompt list uses read-only prompts | Pass if read-only actions show ResultPanel, not text replacement |
| PV-02 | Preview PDF read-only | Long paragraph | Select paragraph text, wait 500 ms, run each read-only prompt | ResultPanel appears with AI output | Pass if original PDF text is unchanged and ResultPanel is visible |

## Edge Cases

| ID | Scenario | Setup steps | Expected result | Pass/fail criteria |
| --- | --- | --- | --- | --- |
| EDGE-01 | Rapid deselect | Select valid text in TextEdit, wait for icon, click elsewhere | Icon disappears | Pass if icon hides and no popover remains |
| EDGE-02 | Select, deselect before clicking | Select valid text, wait for icon, deselect before clicking icon | Icon hides before action | Pass if action cannot be triggered from stale selection |
| EDGE-03 | Snapshot isolation | Select text A, wait for icon, change selection to text B before opening popover | Action uses snapshot captured when latest icon was shown | Pass if result applies to the captured selection/element, not a later nil selection |
| EDGE-04 | External click dismiss | Select text, wait for icon, click another app/window | Icon disappears | Pass if global click monitor dismisses icon |
| EDGE-05 | Select in Quill itself | Select text in Quill UI if any text is selectable | Quill should not self-trigger user-facing action loops | Pass if no recursive icon/popover loop occurs |
| EDGE-06 | Rapid app switching | Select text, Cmd+Tab to another app within 500 ms | Icon should not remain attached to stale app context | Pass if icon hides or updates only for current valid selection |

## Execution Notes

- Always confirm Quill is running first by checking the menu bar sparkles icon.
- Use triple-click or Cmd+A instead of mouse drag where possible.
- Wait at least 500 ms after text selection before asserting icon state.
- Capture screenshots for icon, popover, and ResultPanel verification.
- API response quality is not pass/fail unless the request fails or output is routed incorrectly.
