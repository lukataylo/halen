# Email Reply

> Plugin id: `com.halen.email-reply` · Category: Productivity · Code:
> [`Sources/Halen/Features/EmailReply/`](../../../Sources/Halen/Features/EmailReply/)

⌃⌥E in a mail app drafts a reply to the message you're reading. Reads the
selected / quoted message via AX (re-using `AskHalenContext`), asks Gemma 4
for a reply, and either inserts it at the caret when the caret sits in an
editable field — or copies it to the clipboard and posts a system
notification so the user knows where it went.

## Hotkey scope

Carbon-registered ⌃⌥E (`controlKey + optionKey + ANSI_E`). Fires only when
the frontmost app's bundle id is in `mailBundleIds`:

```swift
static let mailBundleIds: Set<String> = [
    "com.apple.mail",
    "com.microsoft.Outlook",
    "com.readdle.smartemail-Mac",          // Spark
    "it.bloop.airmail2",
    "com.canarymail.mac",
    "com.mimestream.Mimestream",
]
```

Outside this list the hotkey is silently a no-op with a notification
pointing the user at the right apps. Web mail (Gmail in Chrome, Outlook
in Safari) isn't covered — the workaround is to select the message text
first and use ⌃H (Ask Halen) instead.

## Source-text capture

Three candidates in priority order, the first non-empty one wins:

1. **Selected text** — what the user highlighted before pressing ⌃⌥E.
2. **Current paragraph** — the paragraph around the caret in the
   currently-focused field (works when reading a message in a preview
   pane where you can scroll but not select).
3. **Clipboard text** — last resort. Useful when the user just copied the
   message body manually.

If all three are empty, a system notification asks the user to select
the message first.

## Prompt + inference

`InferenceRequest(tier: .medium, maxTokens: 500, temperature: 0.4,
taskKind: .generation)` → Gemma 4 E4B on llama.cpp (or Apple Intelligence
when available). The prompt frames the model as a polite email assistant
and asks for a reply in the same register as the original; tone profiles
are *not* mixed in here yet (that's queued as a follow-up — "on-the-fly
tone selection" in the detail view).

## Write-back

Two paths, picked at runtime:

- **Caret in an editable field** → AX-write the reply at the caret's
  current selection range, using the *captured* `AXUIElement` so a focus
  shift mid-generation doesn't land the text in the wrong field.
- **Caret read-only or unavailable** → copy to clipboard, post a system
  notification ("Reply copied to clipboard — press ⌘V"). Same fallback
  shape as Ask Halen's Insert button.

## Why this plugin is OFF by default

The mail-app whitelist plus the explicit "select first" workflow make
this fundamentally an opt-in tool. Few users would expect ⌃⌥E to "do
something" if they never enabled it on purpose; surfacing it as
default-off via onboarding keeps the system honest.

## What it does NOT do

- **Per-reply tone selection.** "Reply formally", "Reply casually", and
  "Reply concisely" aren't picker options yet. Queued.
- **Threading awareness.** No "this is the third reply, keep it brief"
  heuristic — the model only sees the one message in context.
- **Browser mail.** Gmail-in-Chrome is on the long list of "deserves
  its own pipeline" — needs the WebExtension bridge to be reliable
  before that's worth doing.
