# Halen plugins

Halen supports out-of-process plugins that communicate with the host over
**JSON-RPC 2.0 (newline-delimited) on stdio**. A plugin is any executable —
a Python script, a Node program, a compiled Swift/Go/Rust binary, anything —
that speaks the protocol.

The host discovers installed plugins at:

```
~/Library/Application Support/Halen/Plugins/<plugin-id>/
```

Each subdirectory must contain a `halen-plugin.json` manifest pointing at the
plugin's executable. Halen auto-creates the parent directory on first launch.

## Hello-world plugin

A complete plugin is two files. Drop both into
`~/Library/Application\ Support/Halen/Plugins/com.example.hello/` and
restart Halen.

`halen-plugin.json`:

```jsonc
{
  "id":              "com.example.hello",
  "name":            "Hello",
  "summary":         "Logs every text.pause event.",
  "version":         "0.1.0",
  "halenApiVersion": "0.1",
  "executable":      "/usr/bin/python3",
  "args":            ["plugin.py"],
  "events":          ["text.pause"],
  "permissions":     [],
  "icon":            "hand.wave",
  "category":        "productivity"
}
```

`plugin.py`:

```python
import json, sys

def send(msg): sys.stdout.write(json.dumps(msg) + "\n"); sys.stdout.flush()

for line in sys.stdin:
    msg = json.loads(line)
    if msg.get("method") == "initialize":
        send({"jsonrpc": "2.0", "id": msg["id"], "result": {"capabilities": {}}})
    elif msg.get("method") == "event/text.pause":
        sys.stderr.write(f"text.pause in {msg['params']['payload']['appName']}\n")
        sys.stderr.flush()
    elif msg.get("method") == "shutdown":
        send({"jsonrpc": "2.0", "id": msg["id"], "result": None})
```

Watch it run:

```bash
log stream --predicate 'subsystem == "com.dadiani.halen"' --info
```

Every time you pause typing in any text field you'll see the
`text.pause in <appName>` line from the plugin's stderr forwarded into
Halen's unified log.

## Manifest reference

```jsonc
{
  "id":              "com.example.my-plugin",   // reverse-DNS, persistence key
  "name":            "My plugin",
  "summary":         "One-line description.",
  "version":         "0.1.0",
  "halenApiVersion": "0.1",                     // protocol version

  "executable":      "/usr/bin/python3",        // absolute, or relative to dir
  "args":            ["plugin.py"],
  "env":             { "OPENAI_API_KEY": "..." },

  "events":          ["text.pause", "app.focused"],
  "permissions":     ["ax.write", "inference"],

  "icon":            "calendar",                // SF Symbol
  "category":        "productivity"
}
```

## Protocol cheat sheet

Framing: NDJSON over stdio. One JSON message per line. **stdin** = host →
plugin. **stdout** = plugin → host (responses + plugin requests). **stderr** =
plugin log (host forwards to its unified log).

### Lifecycle (host → plugin)

| Method                     | Kind         | Notes |
|---|---|---|
| `initialize`               | request      | First message, plugin responds with capabilities. |
| `notifications/initialized`| notification | Plugin is live, events start flowing. |
| `shutdown`                 | request      | Polite shutdown, plugin flushes state. |
| `exit`                     | notification | Plugin should exit within ~1s. SIGTERM/SIGKILL after. |

### Events (host → plugin notification)

Topic strings under `event/`. The plugin only receives topics it declared in
its manifest's `events` array.

| Topic         | Payload (under `params.payload`) |
|---|---|
| `text.pause`  | `appBundleId`, `appName`, `text`, `caretOffset`, `timestamp` |
| `caret.moved` | `appBundleId`, `rect: {x,y,width,height}`, `timestamp` |
| `app.focused` | `appBundleId`, `appName`, `timestamp` |
| `hotkey.fired` | `id` (the string the plugin chose at `hotkey/register` time), `timestamp` |
| `finding.detected` | `source` (plugin id of the emitter), `id`, `severity` (`tone`/`conciseness`/`clarity`), `summary`, `timestamp`. Lets a plugin suppress itself when another writing plugin has flagged the paragraph (UX-3). Read-only — there's no host method to *emit* a finding, only subscribe. |
| `finding.cleared` | `source`, `id?` (nil clears every finding from `source`), `timestamp` |

### Host methods (plugin → host request)

| Method                    | Params                                     | Result |
|---|---|---|
| `inference/complete`      | `prompt`, `tier`, `maxTokens?`, `temperature?`, `stop?`, `taskKind?` | `text`, `modelId`, `latencyMs` |
| `ax/replaceRange`         | `location`, `length`, `text`               | `ok: true` |
| `ax/readSelection`        | —                                          | `text`, `appBundleId` |
| `ui/toast`                | `title`, `body`                            | `ok: true` — posts a system notification |
| `ui/prompt`               | `title?`, `body`, `actions: [String]`      | `action` — the chosen action string, or `null` on dismiss / timeout. **Blocks** until the user responds |
| `calendar/upcomingEvents` | `withinHours?` (default 24), `max?` (default 20) | `events: [{ id, title, start, end, attendees, notes }]` — `start`/`end` are epoch seconds |
| `calendar/createEvent`    | `title`, `start` (epoch seconds), `durationMinutes?` (default 30) | `id` — the new event's identifier |
| `hotkey/register`         | `id` (plugin-chosen string), `keyCode` (Carbon virtual key code, e.g. `kVK_ANSI_E` = 14), `modifiers` (Carbon modifier flag bitmask: `controlKey` 0x1000, `optionKey` 0x800, `cmdKey` 0x100, `shiftKey` 0x200) | `ok: true`. The plugin must also list `hotkey.fired` in its manifest `events` to receive the notification when the hotkey is pressed. |
| `hotkey/unregister`       | `id` (matching a prior `hotkey/register`) | `ok: true`. Idempotent; unknown ids return ok without error. |
| `profile/getToneProfile`  | `bundleId` | `tone` (`formal`/`casual`/`neutral`), `label`, `promptClause` — the sentence-form hint Sentiment Guard / Clarity Checker drop into their classifier prompts. |
| `profile/setToneProfile`  | `bundleId`, `tone` (`formal`/`casual`/`neutral`) | `ok: true` or `{ok: false, error: …}`. The host's `AppToneProfileStore` is shared with the in-process writing plugins, so a write takes effect on the next classification. |
| `profile/listToneProfiles` | — | `profiles: [{bundleId, tone, label}]` — sorted by bundle id. |

The `calendar/*` methods are **gated** on the `calendar` permission — the
plugin must list `"calendar"` in its manifest's `permissions` array, and the
host requests the macOS Calendar TCC grant on first use. Without the manifest
permission the call returns error `-32001` (permission denied). The host owns
the single `EKEventStore`; a plugin never links EventKit itself.

The `hotkey/*` methods are ungated — system-wide hotkeys are an annoyance at
worst, not a privilege. Hotkeys are unregistered automatically when the
plugin process terminates, so a misbehaving plugin can't leave a Carbon
registration hanging around. Re-registering the same `id` replaces the
prior binding rather than stacking two on the same key combo.

### Errors

JSON-RPC standard codes plus Halen-specific:

| Code   | Meaning |
|---|---|
| -32601 | Method not found |
| -32602 | Invalid params |
| -32001 | Permission denied |
| -32002 | Inference unavailable |
| -32003 | AX write failed |
