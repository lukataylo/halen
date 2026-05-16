# Halen for Web — browser extension

A tiny Chromium MV3 extension that lets Halen's native plugins
(SnippetExpander, TypoFixer, SentimentGuard, Ask Halen) see typing in
browser text fields. Without it, macOS Accessibility doesn't reach into
Chromium's rendered DOM and Halen is effectively blind in Slack, Discord,
Gmail, Google Docs, Notion, ChatGPT.app's input, etc.

## How it works

```
┌──────────────────┐   ws://127.0.0.1:50765    ┌─────────────────────┐
│  Chrome / Arc /  │  event/text.pause ──────► │  Halen.app          │
│  Edge — DOM      │                           │   WebSocketBridge   │
│  input/textarea  │                           │     ↓               │
│  contenteditable │                           │   EventBus          │
└──────────────────┘                           │     ↓               │
                                               │   SnippetExpander   │
                                               │   TypoFixer         │
                                               │   SentimentGuard    │
                                               │     ↓               │
                                               │   AX write fails    │
                                               │     ↓               │
                                               │   clipboard + ⌘V    │
                                               └─────────────────────┘
                                                        │
                                                        ▼
                                               (paste lands in DOM)
```

Same plugins, same protocol shape — the browser tab is just another event
source. Write-back relies on Halen's existing clipboard-and-⌘V fallback
(Bet 4a) because synthesised ⌘V works perfectly in Chromium text fields.

## Install (Chrome / Edge / Arc / Brave)

1. Open `chrome://extensions/`
2. Toggle on **Developer mode** (top-right)
3. Click **Load unpacked**
4. Pick the `browser-extension/` directory in this repo

The extension's icon appears in the toolbar. Tooltip shows the connection
status (the v0 doesn't render a popup yet — watch the Halen log for
connection events).

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

## Limitations of v0

- Each browser tab opens its own WebSocket connection — Halen accepts an
  unbounded number; if this becomes a problem we'll move to one
  service-worker-owned connection that proxies for all tabs.
- The extension is one-way today: events go up, writes come back via the
  ⌘V clipboard fallback. Future: direct `extension/replaceSelection` RPC
  so writes preserve undo history and avoid clobbering the clipboard.
- Password fields are excluded by design (`<input type="password">`).
- contenteditable caret offset is best-effort — exact for plain text,
  approximate when the editor uses nested elements (Notion, Docs).
