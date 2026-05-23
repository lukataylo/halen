#!/usr/bin/env python3
"""Halen Tone Profiles — out-of-process editor.

The host owns the actual tone-profile store (other in-process writing
plugins read it on every classification — see Sentiment Guard and
Clarity Checker). This plugin is the *editor*: it subscribes to
`app.focused` events to keep a list of recently-seen apps, and it
exposes a hotkey (⌃⌥T) that opens a `ui/prompt` for assigning a tone
to the frontmost app.

The host RPC methods `profile/listToneProfiles`, `profile/getToneProfile`,
and `profile/setToneProfile` (introduced in v0.2.0 for this extraction)
are how the plugin talks to the shared store. The same RPC surface is
what future SentimentGuard / ClarityChecker extractions will use once
they leave the in-process binary.

All privileged operations go through the host over JSON-RPC.
"""
import sys
import os
import json
import threading
import itertools

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


# --- recently-focused apps ---------------------------------------------------

# Same idea as the in-process `RecentAppsModel`: an in-memory tally of
# apps seen this session, so the editor can offer real apps instead of
# asking the user to type bundle ids by hand. The store the host owns
# already knows which apps have an assigned profile; this list is just
# the "unassigned but recently used" surface.
_recent_lock = threading.Lock()
_recent = {}    # bundle_id -> display_name (best-effort; appName from focus events)


def note_focus(payload):
    bundle = (payload or {}).get("appBundleId") or ""
    name   = (payload or {}).get("appName") or bundle
    if not bundle:
        return
    with _recent_lock:
        _recent[bundle] = name


# --- editor hotkey -----------------------------------------------------------

# ⌃⌥T — set the tone for the current frontmost app. The hotkey is global
# so the user can re-flag an app without first opening Halen's marketplace.
HOTKEY_ID    = "set-tone"
KVK_ANSI_T   = 17        # Carbon kVK_ANSI_T
CONTROL_KEY  = 0x1000
OPTION_KEY   = 0x0800


def register_hotkey():
    try:
        call("hotkey/register", {
            "id": HOTKEY_ID,
            "keyCode": KVK_ANSI_T,
            "modifiers": CONTROL_KEY | OPTION_KEY,
        })
        _log("tone-profiles: registered ⌃⌥T")
    except Exception as e:
        _log(f"tone-profiles: hotkey/register failed: {e}")


def set_tone_for_focused():
    # Pull the frontmost app from our recent-apps tally — the most recent
    # entry. The host doesn't push a "current frontmost" lookup over RPC,
    # but every app.focused event we see updates the dict, so the last
    # one in is what's on screen now.
    with _recent_lock:
        if not _recent:
            try:
                call("ui/toast", {
                    "title": "Tone Profiles",
                    "body":  "Focus an app first, then press ⌃⌥T to set its tone.",
                })
            except Exception:
                pass
            return
        # dict preserves insertion order in Python 3.7+. Take the latest.
        bundle, name = next(reversed(_recent.items()))

    # Ask which tone to set. The host's promptPresenter wraps the system
    # modal and returns the chosen string (or null on dismiss).
    try:
        choice = call("ui/prompt", {
            "title":   "Tone Profile",
            "body":    f"Set Halen's tone for {name}.",
            "actions": ["Formal", "Casual", "Neutral", "Cancel"],
        })
    except Exception as e:
        _log(f"tone-profiles: ui/prompt failed: {e}")
        return

    action = (choice or {}).get("action") or ""
    if action == "Cancel" or not action:
        return
    tone = action.lower()
    if tone not in ("formal", "casual", "neutral"):
        return

    try:
        resp = call("profile/setToneProfile", {"bundleId": bundle, "tone": tone})
    except Exception as e:
        _log(f"tone-profiles: setToneProfile failed: {e}")
        return
    if not (resp or {}).get("ok"):
        err = (resp or {}).get("error") or "unknown error"
        _log(f"tone-profiles: setToneProfile rejected: {err}")
        try:
            call("ui/toast", {
                "title": "Tone Profiles",
                "body":  f"Couldn't save: {err}",
            })
        except Exception:
            pass
        return
    try:
        call("ui/toast", {
            "title": "Tone Profile saved",
            "body":  f"{name} → {action}",
        })
    except Exception:
        pass
    _log(f"tone-profiles: {bundle} → {tone}")


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
            threading.Thread(target=register_hotkey, daemon=True).start()
        elif method == "shutdown":
            _stop.set()
            try:
                call("hotkey/unregister", {"id": HOTKEY_ID}, timeout=2)
            except Exception:
                pass
            _send({"jsonrpc": "2.0", "id": msg["id"], "result": None})
        elif method == "exit":
            _stop.set()
            break
        elif method == "event/app.focused":
            note_focus((msg.get("params") or {}).get("payload") or {})
        elif method == "event/hotkey.fired":
            payload = (msg.get("params") or {}).get("payload") or {}
            if payload.get("id") == HOTKEY_ID:
                threading.Thread(target=set_tone_for_focused, daemon=True).start()
        elif method is None and "id" in msg:
            _resolve(msg)

    _stop.set()


if __name__ == "__main__":
    main()
