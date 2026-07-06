#!/usr/bin/env python3
"""Clipboard Cleaner — the smallest useful Halen plugin.

Press ⌃⌥⇧V and whatever is on your clipboard gets cleaned in place:
tracking parameters stripped from URLs, whitespace collapsed, smart
quotes straightened. That's it.

It exists as the living documentation for PLUGINS.md: one JSON manifest,
one script, newline-delimited JSON-RPC 2.0 over stdio. No SDK, no build
step. Everything it can touch is declared in halen-plugin.json and
enforced by the host — try removing "clipboard" from the manifest and
watch the clipboard/read call come back with error -32001.
"""

import json
import re
import sys
from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode

TRACKING_PARAMS = {
    "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
    "gclid", "fbclid", "igshid", "mc_eid", "vero_id", "yclid", "wickedid",
}

_next_id = 0
_pending = {}  # id -> description, for debugging via stderr


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def request(method, params=None):
    """Send a request to the host; the response arrives on stdin and is
    handled by the main loop, which resolves it back to us synchronously
    (this plugin only ever has one call in flight)."""
    global _next_id
    _next_id += 1
    send({"jsonrpc": "2.0", "id": _next_id, "method": method, "params": params or {}})
    for line in sys.stdin:
        msg = json.loads(line)
        if msg.get("id") == _next_id and "method" not in msg:
            if "error" in msg and msg["error"]:
                print(f"host error for {method}: {msg['error']}", file=sys.stderr)
                return None
            return msg.get("result")
        handle(msg)  # an event arrived while we were waiting — deal with it
    return None


def clean(text):
    # Straighten smart quotes, collapse runs of blank lines and spaces.
    text = text.replace("“", '"').replace("”", '"')
    text = text.replace("‘", "'").replace("’", "'")
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text).strip()

    # If it's a single URL, strip tracking params.
    if re.fullmatch(r"https?://\S+", text):
        parts = urlsplit(text)
        kept = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True)
                if k.lower() not in TRACKING_PARAMS]
        text = urlunsplit(parts._replace(query=urlencode(kept)))
    return text


def on_hotkey():
    result = request("clipboard/read")
    original = (result or {}).get("text")
    if not original:
        return
    cleaned = clean(original)
    if cleaned == original:
        request("ui/toast", {"title": "Clipboard Cleaner", "body": "Already clean."})
        return
    request("clipboard/write", {"text": cleaned})
    request("ui/toast", {"title": "Clipboard Cleaner",
                         "body": f"Cleaned {len(original) - len(cleaned)} characters of junk."})


def handle(msg):
    method = msg.get("method")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": msg["id"], "result": {}})
        # kVK_ANSI_V = 9; modifiers = control(4096) | option(2048) | shift(512)
        request("hotkey/register", {"id": "clean", "keyCode": 9, "modifiers": 6656})
    elif method == "shutdown":
        send({"jsonrpc": "2.0", "id": msg["id"], "result": {}})
    elif method == "exit":
        sys.exit(0)
    elif method == "event/hotkey.fired":
        on_hotkey()


def main():
    for line in sys.stdin:
        try:
            handle(json.loads(line))
        except Exception as e:  # one bad message shouldn't kill the plugin
            print(f"clipboard-cleaner: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
