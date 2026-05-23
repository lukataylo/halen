#!/usr/bin/env python3
"""Halen Inline Autocomplete — out-of-process plugin.

Pause while typing and the plugin asks the local model for a short
continuation. The suggestion is *held* (not inserted) and Tab is
registered as a hot-key; pressing Tab inserts it via ax/replaceRange.
Any other event (caret move, app focus change, new text.pause) drops
the pending suggestion and unregisters Tab.

This mirrors the in-process Swift Autocomplete plugin's accept-on-Tab
flow. The big UX regression: external plugins can't draw the gray
"ghost text" overlay the in-process version uses. The suggestion is
invisible until accepted — confirm-by-tab without preview. A future
`ui/ghostText` host method (or richer overlay RPC) would restore the
ghost preview, but until then the flow is "pause, trust the model, hit
Tab to find out what it wrote."

All privileged operations go through the host over JSON-RPC.
"""
import sys
import os
import json
import threading
import itertools
import time

# --- JSON-RPC plumbing -------------------------------------------------------

_ids = itertools.count(1)
_ids_lock = threading.Lock()
_out_lock = threading.Lock()
_pending = {}
_pending_lock = threading.Lock()
_stop = threading.Event()


def _send(msg):
    line = json.dumps(msg) + "\n"
    with _out_lock:
        sys.stdout.write(line)
        sys.stdout.flush()


def _log(text):
    sys.stderr.write(text + "\n")
    sys.stderr.flush()


def call(method, params, timeout=180):
    with _ids_lock:
        rid = next(_ids)
    event = threading.Event()
    slot = {}
    with _pending_lock:
        _pending[rid] = (event, slot)
    _send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
    if not event.wait(timeout):
        with _pending_lock:
            _pending.pop(rid, None)
        raise TimeoutError(f"{method} timed out")
    if "error" in slot:
        raise RuntimeError(f"{method}: {slot['error']}")
    return slot.get("result")


def _resolve(msg):
    with _pending_lock:
        entry = _pending.pop(msg.get("id"), None)
    if not entry:
        return
    event, slot = entry
    if "error" in msg:
        slot["error"] = msg["error"]
    else:
        slot["result"] = msg.get("result")
    event.set()


# --- settings ----------------------------------------------------------------

_PLUGIN_DIR  = os.environ.get("HALEN_PLUGIN_DIR") or os.path.dirname(os.path.abspath(__file__))
_SETTINGS    = os.path.join(_PLUGIN_DIR, "settings.json")

# Mirrors the in-process Autocomplete settings shipped in v0.2.0:
#   extraSettleMs — extra debounce on top of text.pause, 0…500
#   appWhitelist  — list of bundle ids; empty = suggest everywhere
DEFAULT_SETTINGS = {"extraSettleMs": 0, "appWhitelist": []}
MIN_CONTEXT_LEN = 20    # don't suggest until enough context is on the right side
MAX_INSERT_LEN  = 80    # cap suggestions — long completions belong in the snippet expander


def load_settings():
    if not os.path.exists(_SETTINGS):
        return dict(DEFAULT_SETTINGS)
    try:
        with open(_SETTINGS, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        _log(f"autocomplete: settings.json unreadable ({e}); using defaults")
        return dict(DEFAULT_SETTINGS)
    out = dict(DEFAULT_SETTINGS)
    out.update(data)
    return out


# --- state -------------------------------------------------------------------

# Tab hotkey identifier — the string the host echoes back in hotkey.fired
# events so we know our own registration fired.
HOTKEY_ID    = "accept"
KVK_TAB      = 48       # Carbon kVK_Tab
NO_MODIFIERS = 0

_state_lock = threading.Lock()
_pending_suggestion = None  # str or None
_pending_position   = None  # int — caret offset where the suggestion belongs
# Generation counter — bumped on every state change. Inference responses
# are checked against the generation that was current when the request
# fired; out-of-date responses are dropped on the floor.
_generation = 0
# Active in-process findings from other writing plugins. While the set is
# non-empty we stand down — same UX-3 collision avoidance the in-process
# version implements.
_active_findings = set()


def _bump_generation():
    global _generation
    _generation += 1
    return _generation


def _accept_register():
    """Register Tab. Idempotent — re-registering replaces the prior binding."""
    try:
        call("hotkey/register", {
            "id": HOTKEY_ID,
            "keyCode": KVK_TAB,
            "modifiers": NO_MODIFIERS,
        }, timeout=5)
    except Exception as e:
        _log(f"autocomplete: hotkey/register Tab failed: {e}")


def _accept_unregister():
    try:
        call("hotkey/unregister", {"id": HOTKEY_ID}, timeout=2)
    except Exception:
        pass


def _drop_suggestion():
    """Clear any pending suggestion and unbind Tab."""
    global _pending_suggestion, _pending_position
    with _state_lock:
        had_one = _pending_suggestion is not None
        _pending_suggestion = None
        _pending_position = None
        _bump_generation()
    if had_one:
        _accept_unregister()


# --- main flow ---------------------------------------------------------------

def maybe_suggest(payload):
    """Handle a text.pause event: maybe fire an inference request."""
    settings = load_settings()
    bundle_id = payload.get("appBundleId") or ""

    # App whitelist gate.
    whitelist = settings.get("appWhitelist") or []
    if whitelist and bundle_id not in whitelist:
        _drop_suggestion()
        return

    # Active-finding gate. Don't suggest while other writing plugins are
    # flagging the paragraph — UX-3.
    with _state_lock:
        if _active_findings:
            return

    text = payload.get("text") or ""
    caret = int(payload.get("caretOffset") or 0)
    if len(text) < MIN_CONTEXT_LEN or caret < len(text):
        # Only suggest at end-of-text. Mid-paragraph ghost text would
        # overlap real content anyway (and the in-process version
        # follows the same rule).
        return

    # Extra settle delay.
    extra_ms = int(settings.get("extraSettleMs") or 0)
    if extra_ms > 0:
        time.sleep(extra_ms / 1000.0)
        # Bail out if anything happened during the sleep.
        with _state_lock:
            if _active_findings:
                return

    # Prompt: short, low-temperature continuation.
    prompt = (
        "Continue the text below with the next few words the user would "
        "naturally type next. Output only the continuation — no preamble, "
        "no quotes, no explanation. Keep it short: 4–10 words at most.\n\n"
        f"Text: \"\"\"{text[-2000:]}\"\"\"\n\nContinuation:"
    )

    my_gen = _bump_generation()
    try:
        resp = call("inference/complete", {
            "prompt": prompt,
            "tier": "small",
            "maxTokens": 24,
            "temperature": 0.3,
            "taskKind": "generation",
        }, timeout=20)
    except Exception as e:
        _log(f"autocomplete: inference failed: {e}")
        return

    # Drop late responses — a newer text.pause could've already
    # superseded this one.
    with _state_lock:
        if my_gen != _generation:
            return
    suggestion = ((resp or {}).get("text") or "").strip()
    # The model sometimes echoes back framing; strip common cruft.
    if suggestion.startswith('"') and suggestion.endswith('"'):
        suggestion = suggestion[1:-1].strip()
    if not suggestion or len(suggestion) > MAX_INSERT_LEN:
        return

    # Stash + register Tab.
    with _state_lock:
        global _pending_suggestion, _pending_position
        _pending_suggestion = suggestion
        _pending_position = caret
    _accept_register()
    # Toast as a visibility signal — the user has no other indicator
    # the suggestion is ready. ui/toast is non-blocking.
    try:
        call("ui/toast", {
            "title": "Halen suggests",
            "body":  f"Tab to insert: “{suggestion}”",
        })
    except Exception:
        pass


def accept():
    """Tab fired — insert the pending suggestion."""
    with _state_lock:
        suggestion = _pending_suggestion
        pos = _pending_position
    if not suggestion:
        return
    # Insert at position 0 length 0 — ax/replaceRange's current API
    # doesn't take a target location independently of the field's current
    # caret; it relies on the AX selected range. The host's
    # CaretObserver.replaceRange substitutes at the current caret, which
    # is where we want the suggestion to land. The `location` / `length`
    # params are interpreted in the field's text frame; 0/0 means "at the
    # current caret with no replacement of existing text."
    try:
        call("ax/replaceRange", {
            "location": 0,
            "length":   0,
            "text":     suggestion,
        })
    except Exception as e:
        _log(f"autocomplete: ax/replaceRange failed: {e}")
    _drop_suggestion()


# --- event handling ----------------------------------------------------------

def handle_text_pause(payload):
    threading.Thread(target=maybe_suggest, args=(payload,), daemon=True).start()


def handle_caret_moved(_payload):
    _drop_suggestion()


def handle_app_focused(_payload):
    _drop_suggestion()


def handle_finding_detected(payload):
    src = payload.get("source") or ""
    if not src:
        return
    with _state_lock:
        _active_findings.add(src)
    _drop_suggestion()


def handle_finding_cleared(payload):
    src = payload.get("source") or ""
    with _state_lock:
        _active_findings.discard(src)


# --- main loop ---------------------------------------------------------------

def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue

        method = msg.get("method")
        if method == "initialize":
            _send({"jsonrpc": "2.0", "id": msg["id"],
                   "result": {"capabilities": {}}})
        elif method == "notifications/initialized":
            pass
        elif method == "shutdown":
            _stop.set()
            _accept_unregister()
            _send({"jsonrpc": "2.0", "id": msg["id"], "result": None})
        elif method == "exit":
            _stop.set()
            break
        elif method == "event/text.pause":
            handle_text_pause((msg.get("params") or {}).get("payload") or {})
        elif method == "event/caret.moved":
            handle_caret_moved((msg.get("params") or {}).get("payload") or {})
        elif method == "event/app.focused":
            handle_app_focused((msg.get("params") or {}).get("payload") or {})
        elif method == "event/hotkey.fired":
            payload = (msg.get("params") or {}).get("payload") or {}
            if payload.get("id") == HOTKEY_ID:
                # Hotkey fires on the host's main thread; off-load to a
                # worker so any slow AX write doesn't block stdin reading.
                threading.Thread(target=accept, daemon=True).start()
        elif method == "event/finding.detected":
            handle_finding_detected((msg.get("params") or {}).get("payload") or {})
        elif method == "event/finding.cleared":
            handle_finding_cleared((msg.get("params") or {}).get("payload") or {})
        elif method is None and "id" in msg:
            _resolve(msg)

    _stop.set()


if __name__ == "__main__":
    main()
