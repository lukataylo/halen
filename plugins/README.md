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

The `calendar/*` methods are **gated** on the `calendar` permission — the
plugin must list `"calendar"` in its manifest's `permissions` array, and the
host requests the macOS Calendar TCC grant on first use. Without the manifest
permission the call returns error `-32001` (permission denied). The host owns
the single `EKEventStore`; a plugin never links EventKit itself.

### Errors

JSON-RPC standard codes plus Halen-specific:

| Code   | Meaning |
|---|---|
| -32601 | Method not found |
| -32602 | Invalid params |
| -32001 | Permission denied |
| -32002 | Inference unavailable |
| -32003 | AX write failed |
