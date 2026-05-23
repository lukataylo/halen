# email-reply (out-of-process plugin)

A Python port of the in-process Email Reply plugin. Drafts a polite
reply to whatever message you've selected in a native mail app, in the
tone you configured. Uses the same `⌃⌥E` hotkey via the new
`hotkey/register` host RPC.

## Status

**v0.2.0 ships the in-process Swift version as the default.** This
external plugin exists as a reference implementation and a preview of
the post-extraction shape. To try it manually:

```sh
cp -R /path/to/halen/plugins/email-reply \
      ~/Library/Application\ Support/Halen/Plugins/
```

The in-process plugin registers first with the same id
(`com.halen.email-reply`), so the external version is skipped today.
The full cutover lands in v0.3.0 with the bundled-plugin auto-install
path. See [docs/PLUGIN_EXTRACTION.md](../../docs/PLUGIN_EXTRACTION.md).

## What's different from in-process

| Concern | In-process Swift | External Python |
|---|---|---|
| Hotkey registration | `HotkeyRegistrar` (in-process Carbon) | `hotkey/register` RPC (host owns Carbon) |
| Frontmost-app gating | `NSWorkspace.shared.frontmostApplication` | `app.focused` event subscription |
| Source-text capture | `AskHalenContext.capture(…)` (selection ▸ paragraph ▸ clipboard) | `ax/readSelection` RPC only — paragraph + clipboard fallbacks need new host methods |
| Tone profile | Reads `services.toneProfiles` directly | Plugin-local default in `settings.json`; per-app profile read deferred until `profile/getToneProfile` lands |
| Draft delivery | AX-write at the caret, else clipboard + notification | `ui/prompt` asks the user where to put the draft, then `ax/replaceRange` or toast |
| Settings | SwiftUI detail view | `settings.json` in `$HALEN_PLUGIN_DIR` |

The user-facing UX regressions vs in-process:

- Capture only sees selected text, not the paragraph or clipboard. Most
  users select the message before pressing ⌃⌥E anyway.
- Draft delivery is a system modal asking Insert / Copy rather than an
  AX-write-when-possible fall-through. A future `clipboard/set` RPC and
  a richer `ax/readSelection` (returning the selected range) would let
  the external plugin match in-process behaviour exactly.

## Files

- `halen-plugin.json` — manifest; declares the `hotkey.fired` and
  `app.focused` event subscriptions and the `inference` permission.
- `plugin.py` — main script. Speaks NDJSON over stdio.
- `settings.json` — created on first save in `$HALEN_PLUGIN_DIR`. Holds
  the `tone` preset choice (`match` / `formal` / `casual` / `concise` /
  `warm`).
