# autocomplete (out-of-process plugin)

A Python port of the in-process Inline Autocomplete plugin. Pause while
typing and the plugin asks the local model for a short continuation;
Tab inserts it.

## Status

**v0.2.0 ships the in-process Swift version as the default.** This
external plugin exists as a reference implementation and a preview of
the post-extraction shape. See
[docs/PLUGIN_EXTRACTION.md](../../docs/PLUGIN_EXTRACTION.md).

## The UX regression

External plugins can't draw the gray "ghost text" overlay the
in-process version uses — there's no host RPC method for compositing
SwiftUI views into a floating panel. The trade-off this external
version makes:

- Suggestion is *invisible* until accepted. A `ui/toast` fires when the
  suggestion is ready ("Tab to insert: …") as the only visibility hint.
- Tab inserts; any other event (caret move, app switch, new text.pause)
  drops the suggestion silently.

This is materially worse than the in-process ghost preview. A future
`ui/ghostText` host method (or richer overlay RPC) would restore
preview parity.

## What's preserved

- **App whitelist** — same `settings.json` schema as in-process (empty
  list = suggest everywhere).
- **Extra-settle delay** — same 0–500 ms range applied on top of
  `text.pause`.
- **UX-3 collision avoidance** — subscribes to `finding.detected` /
  `finding.cleared`, stands down while any writing plugin has an active
  finding. Newly possible thanks to the protocol additions in this
  extraction.
- **Generation counter** — late inference responses (when a newer
  `text.pause` has already superseded) are dropped on the floor.
- **End-of-text only** — won't suggest mid-paragraph.

## Files

- `halen-plugin.json` — manifest. Declares the unusually broad event
  set (`text.pause`, `caret.moved`, `app.focused`, `hotkey.fired`,
  `finding.detected`, `finding.cleared`) the plugin needs.
- `plugin.py` — main script.
- `settings.json` — created on first save. Holds `extraSettleMs` and
  `appWhitelist`.
