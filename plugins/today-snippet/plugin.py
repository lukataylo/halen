#!/usr/bin/env python3
"""
Sample Halen out-of-process plugin. Demonstrates the JSON-RPC plugin protocol
end-to-end without needing a Swift toolchain:

  1. Subscribes to `event/text.pause` (declared in halen-plugin.json).
  2. Detects the `;today` snippet trigger right before the caret.
  3. Calls `ax/replaceRange` on the host to swap the trigger for the
     current date.

Run by Halen — not directly. See README at the repo's `plugins/` directory.
"""
import sys
import json
import datetime

# --- Outgoing message helpers -------------------------------------------------

NEXT_REQUEST_ID = 1


def write_message(msg):
    """NDJSON framing — one JSON message per line, no embedded raw newlines.
    JSON encoders escape newlines inside strings to `\\n`, so the line
    terminator is always unambiguous."""
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def log(text):
    """Plugin log channel — host forwards stderr lines to its unified log."""
    sys.stderr.write(f"{text}\n")
    sys.stderr.flush()


def notify(method, params=None):
    msg = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        msg["params"] = params
    write_message(msg)


def call(method, params=None):
    """Fire a request. We don't currently wait on the response — the host
    returns ok/error and either way we're done. A more elaborate plugin would
    track pending responses by id and resume on receipt."""
    global NEXT_REQUEST_ID
    msg = {"jsonrpc": "2.0", "id": NEXT_REQUEST_ID, "method": method}
    if params is not None:
        msg["params"] = params
    NEXT_REQUEST_ID += 1
    write_message(msg)


# --- Lifecycle ---------------------------------------------------------------


def handle_initialize(msg_id, _params):
    write_message({
        "jsonrpc": "2.0",
        "id": msg_id,
        "result": {
            "protocolVersion": "0.1",
            "pluginInfo": {"name": "today-snippet", "version": "0.1.0"},
            "capabilities": {
                "events": {"text.pause": True}
            }
        }
    })
    log("today-snippet: initialized")


def handle_shutdown(msg_id, _params):
    write_message({"jsonrpc": "2.0", "id": msg_id, "result": None})


def handle_exit(_msg_id, _params):
    sys.exit(0)


# --- Trigger detection -------------------------------------------------------

SNIPPET = ";today"
DATE_FORMAT = "%A %B %d, %Y"   # "Friday May 16, 2026"


def handle_text_pause(payload):
    text = payload.get("text") or ""
    caret = payload.get("caretOffset", 0)
    if not text:
        return

    # The trigger fires once the user has typed `;today` followed by a
    # separator (space / punctuation). Restrict the search window to the few
    # characters immediately before the caret so we don't accidentally re-
    # expand if the same string appears earlier in the buffer.
    window_start = max(0, caret - len(SNIPPET) - 2)
    tail = text[window_start:caret]
    if SNIPPET not in tail:
        return

    # Confirm there's a separator after the trigger (the canonical
    # "user finished typing the word" signal — matches the in-process
    # SnippetExpander's word-boundary rule).
    sep_pos = window_start + tail.rindex(SNIPPET) + len(SNIPPET)
    if sep_pos >= len(text):
        return
    next_char = text[sep_pos]
    if not (next_char.isspace() or next_char in ".,;:!?"):
        return

    idx = window_start + tail.rindex(SNIPPET)
    today = datetime.date.today().strftime(DATE_FORMAT)
    log(f"expanding ;today at offset {idx} -> {today!r}")
    call("ax/replaceRange", {
        "location": idx,
        "length": len(SNIPPET),
        "text": today
    })


# --- Dispatch ----------------------------------------------------------------


REQUEST_HANDLERS = {
    "initialize": handle_initialize,
    "shutdown": handle_shutdown,
    "exit": handle_exit,                # exit is technically a notification
}

NOTIFICATION_HANDLERS = {
    "exit": handle_exit,
    "notifications/initialized": lambda _params: None,
}


def main():
    log("today-snippet: starting")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError as e:
            log(f"bad JSON from host: {e}")
            continue

        method = msg.get("method")
        msg_id = msg.get("id")

        if method == "initialize":
            handle_initialize(msg_id, msg.get("params"))
        elif method == "shutdown":
            handle_shutdown(msg_id, msg.get("params"))
        elif method == "exit":
            handle_exit(msg_id, msg.get("params"))
        elif method and method.startswith("event/"):
            topic = method.removeprefix("event/")
            params = msg.get("params") or {}
            payload = params.get("payload") or {}
            if topic == "text.pause":
                handle_text_pause(payload)
        # Responses to our own calls land here too; we ignore them in this
        # one-shot plugin. A long-running plugin would dispatch on `id`.


if __name__ == "__main__":
    main()
