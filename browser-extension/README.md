# Halen for Web — browser extension

A tiny Chromium MV3 extension that lets Halen's native plugins
(SnippetExpander, TypoFixer, SentimentGuard, Ask Halen) see typing in
browser text fields. Without it, macOS Accessibility doesn't reach into
Chromium's rendered DOM and Halen is effectively blind in Slack, Discord,
Gmail, Google Docs, Notion, ChatGPT.app's input, etc.

## How it works

```
┌──────────────────┐  runtime message  ┌────────────────┐
│ Browser tabs     │ event/text.pause ►│ MV3 background │
│ DOM edit fields  │                   │ service worker │
└──────────────────┘                   └───────┬────────┘
                                              │ one authenticated WebSocket
                                              ▼
                                    ┌─────────────────────┐
                                    │ Halen WebSocketBridge│
                                    │ EventBus → plugins   │
                                    │ clipboard + ⌘V       │
                                    └─────────────────────┘
```

All tabs send events to one MV3 background service worker, which owns the
single authenticated WebSocket. The token is presented as a WebSocket
subprotocol, so the connection opens only after authentication. Write-back relies on Halen's
clipboard-and-⌘V fallback
because synthesised ⌘V works perfectly in Chromium text fields.

The bridge is authenticated: loopback binding alone isn't a trust boundary
(any local process could connect), so every client must present a **pairing
token** before it can send or receive events.

## Install (Chrome / Edge / Arc / Brave)

1. Open `chrome://extensions/`
2. Toggle on **Developer mode** (top-right)
3. Click **Load unpacked**
4. Pick the `browser-extension/` directory in this repo
5. In **Halen Settings → Browser bridge**, enable the bridge.
6. **Pair it.** Click the extension's toolbar icon to open its popup, then
   paste the pairing token from **Halen Settings → Browser bridge**. Until
   the token matches, the connection opens but Halen ignores its events.

The extension's popup shows the connection status; you can also watch the
Halen log for connection events.

## Verify

With Halen running and the extension loaded:

```bash
log stream --predicate 'subsystem == "com.dadiani.halen"' --info \
  | grep -i websocket
```

Open a new browser tab, focus a text input, and type. You should see:

```
WebSocketBridge: listening on 127.0.0.1:50765
WebSocketBridge: client a1b2c3d4 connected (1 total)
```

Then trigger a snippet — type `;sig ` in Slack web, Gmail compose, or a
Google Doc. Halen's SnippetExpander fires, the AX write fails (silently),
the clipboard fallback kicks in, ⌘V is synthesised, and your signature
lands in the field.

## Security and lifecycle

- Halen accepts WebSocket upgrades only from Chrome, Firefox, or Safari
  extension origins; ordinary web pages and origin-less clients are rejected.
- The background worker authenticates during the WebSocket upgrade and keeps
  the one socket alive with periodic traffic. Chrome 116+ is required for reliable MV3
  WebSocket liveness.
- The paired extension can publish supported events only. It receives no host
  RPC capabilities.
- Text is windowed around the caret to 32K UTF-16 units, and the background
  worker refuses events over 192 KiB before retaining or sending them.

## Limitations of v0

- One service-worker-owned connection proxies events for all tabs. Halen caps
  the bridge at 16 simultaneous clients across installed browser profiles.
- The extension is one-way today: events go up, writes come back via the
  ⌘V clipboard fallback. Future: direct `extension/replaceSelection` RPC
  so writes preserve undo history and avoid clobbering the clipboard.
- Password fields are excluded by design (`<input type="password">`).
- contenteditable caret offset is best-effort — exact for plain text,
  approximate when the editor uses nested elements (Notion, Docs).
