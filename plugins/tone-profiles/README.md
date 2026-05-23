# tone-profiles (out-of-process plugin)

A Python port of the in-process Tone Profiles plugin. The host owns the
tone-profile store (so other in-process plugins keep working); this
plugin is purely the editor surface.

## Status

**v0.2.0 ships the in-process Swift version as the default.** This
external plugin exists as a reference implementation and a preview.
See [docs/PLUGIN_EXTRACTION.md](../../docs/PLUGIN_EXTRACTION.md).

The extraction introduced three new host RPC methods so the editor
and the in-process readers (Sentiment Guard, Clarity Checker) can
share the same store:

- `profile/getToneProfile(bundleId)` → `{tone, label, promptClause}`
- `profile/setToneProfile(bundleId, tone)` → `{ok}`
- `profile/listToneProfiles()` → `{profiles: [{bundleId, tone, label}]}`

## What it does

- Tracks recently-focused apps via the `app.focused` event subscription.
- Registers ⌃⌥T as a hotkey. When the user presses it, the plugin
  asks `profile/setToneProfile` to assign a tone (Formal / Casual /
  Neutral) to the frontmost app.

The editor's bulk-assignment UI from the in-process detail view
(checkbox + apply-tone-to-many) needs a richer host UI surface than
`ui/prompt` provides today — that's deferred. The hotkey path is
enough for "I'm in Slack right now and I want it casual."

## What it does NOT do (yet)

- **No bulk-assignment UI.** The in-process detail view has a
  multi-select + apply-tone affordance; reproducing it externally
  needs a richer host UI method than `ui/prompt`.
- **No persistence of recent apps.** The list is rebuilt from
  `app.focused` events each session — same as the in-process model.
- **No prompt-clause editor.** The clauses are baked into the host's
  `ToneProfile` enum and can't be customised from this plugin.

## Files

- `halen-plugin.json` — manifest. Declares `app.focused` and
  `hotkey.fired` subscriptions, no permissions.
- `plugin.py` — main script.
