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

## Try the sample

```bash
mkdir -p ~/Library/Application\ Support/Halen/Plugins
cp -r plugins/today-snippet ~/Library/Application\ Support/Halen/Plugins/
```

Restart Halen. Now type `;today ` (with a trailing space) in any text field —
the trigger expands to today's date, like the built-in `SnippetExpander` does
for `;today` already, except the implementation lives in a 90-line Python
script outside the app.

Watch what's happening:

```bash
log stream --predicate 'subsystem == "com.dadiani.halen"' --info
```

You'll see `plugin[com.halen.today-snippet] expanding ;today at offset N → ...`
from the plugin's stderr forwarded into the host's unified log.

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

| Method               | Params                                     | Result |
|---|---|---|
| `inference/complete` | `prompt`, `tier`, `maxTokens?`, `temperature?`, `stop?`, `taskKind?` | `text`, `modelId`, `latencyMs` |
| `ax/replaceRange`    | `location`, `length`, `text`               | `ok: true` |
| `ax/readSelection`   | —                                          | `text`, `appBundleId` |
| `ui/toast`           | `title`, `body`                            | `ok: true` |

### Errors

JSON-RPC standard codes plus Halen-specific:

| Code   | Meaning |
|---|---|
| -32601 | Method not found |
| -32602 | Invalid params |
| -32001 | Permission denied |
| -32002 | Inference unavailable |
| -32003 | AX write failed |
