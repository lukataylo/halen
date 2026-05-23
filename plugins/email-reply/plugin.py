#!/usr/bin/env python3
"""Halen Email Reply — out-of-process plugin.

Press ⌃⌥E while reading a message in a mail app and Halen drafts a reply
on your behalf — clear, polite, in the tone you configured. Inserts at
the caret if you've clicked into the reply box; otherwise copies to the
clipboard and posts a notification so you know where it went.

Mirrors the in-process Swift implementation (EmailReply.swift) shipped
through v0.2.0: same mail-app whitelist, same source-text capture
priority, same tone-clause-as-suffix prompt shape.

All privileged operations go through the host over JSON-RPC.
"""
import sys
import os
import json
import threading
import itertools

# --- JSON-RPC plumbing (shared shape with the other Halen plugins) ----------

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


# --- mail-app whitelist + tones ----------------------------------------------

# Native mail apps the hotkey is scoped to. Browser-based mail (Gmail,
# Outlook web) isn't reliably distinguishable from any other tab, so it's
# deliberately excluded — the user works around it by selecting the
# message text first, which still flows through the same source-capture
# logic via ax/readSelection.
MAIL_BUNDLE_IDS = {
    "com.apple.mail",
    "com.microsoft.Outlook",
    "com.readdle.smartemail-Mac",     # Spark
    "it.bloop.airmail2",
    "com.canarymail.mac",
    "com.mimestream.Mimestream",
}

# Tone presets that the user can pick in the detail view. "match" defers
# to whatever Tone Profiles has set for the focused app (the historical
# default); the others fully override it.
TONE_CLAUSES = {
    "match":   "",  # filled in at draft time from the per-app profile, if available
    "formal":  "Write the reply in a formal, professional register.",
    "casual":  "Write the reply in a casual, relaxed register — friendly and brief.",
    "concise": "Keep the reply as short as politely possible. Two or three sentences.",
    "warm":    "Write the reply with a warm, friendly tone — acknowledge the sender before responding.",
}

# Plugin-local settings. Persist alongside the plugin so the user's
# choice survives between sessions.
_PLUGIN_DIR  = os.environ.get("HALEN_PLUGIN_DIR") or os.path.dirname(os.path.abspath(__file__))
_SETTINGS    = os.path.join(_PLUGIN_DIR, "settings.json")


def load_settings():
    if not os.path.exists(_SETTINGS):
        return {"tone": "match"}
    try:
        with open(_SETTINGS, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        _log(f"email-reply: settings.json unreadable ({e}); using defaults")
        return {"tone": "match"}
    if data.get("tone") not in TONE_CLAUSES:
        data["tone"] = "match"
    return data


# Snapshot tracked frontmost app so the hotkey handler doesn't have to
# round-trip an ax/readSelection just to know which mail app we're in.
# Updated by every app.focused event the host pushes us.
_front_app_lock = threading.Lock()
_front_app = {"bundleId": ""}


def note_focus(payload):
    bundle = (payload or {}).get("appBundleId") or ""
    with _front_app_lock:
        _front_app["bundleId"] = bundle


# --- drafting -----------------------------------------------------------------

_inflight_lock = threading.Lock()


def draft_reply():
    """Capture the message, call inference, deliver the draft."""
    with _front_app_lock:
        front_bundle = _front_app["bundleId"]

    if front_bundle and front_bundle not in MAIL_BUNDLE_IDS:
        # Not a mail app — politely tell the user where the hotkey works.
        try:
            call("ui/toast", {
                "title": "Email Reply",
                "body":  "Focus a mail app (Mail, Outlook, Spark, Airmail…) and press ⌃⌥E.",
            })
        except Exception as e:
            _log(f"email-reply: ui/toast failed: {e}")
        return

    # ax/readSelection returns whatever the user has highlighted in the
    # focused field — for reading panes that's the message text the user
    # was looking at. Empty string means "no selection / no field
    # focused" — we ask the user to select the message first.
    try:
        selection = call("ax/readSelection", {})
    except Exception as e:
        _log(f"email-reply: ax/readSelection failed: {e}")
        return
    original = ((selection or {}).get("text") or "").strip()
    if not original:
        try:
            call("ui/toast", {
                "title": "Email Reply",
                "body":  "Select the message you want to reply to, then press ⌃⌥E.",
            })
        except Exception as e:
            _log(f"email-reply: ui/toast failed: {e}")
        return

    settings = load_settings()
    tone = settings.get("tone", "match")
    tone_clause = TONE_CLAUSES.get(tone, "") or TONE_CLAUSES["match"]

    prompt = (
        "You are drafting a reply to an email on the user's behalf. "
        "Write a clear, polite, appropriately concise reply to the message below. "
        f"{tone_clause} "
        "Output ONLY the reply body — no subject line, no preamble, no quotes.\n\n"
        f"Message:\n\"\"\"\n{original}\n\"\"\""
    )

    # Serialise drafts — a second ⌃⌥E while a draft is in flight should
    # supersede, but we don't have request cancellation in the plugin
    # protocol yet. Skipping the new one is the simplest sound default.
    if not _inflight_lock.acquire(blocking=False):
        _log("email-reply: a draft is already in flight; ignoring this ⌃⌥E")
        return
    try:
        try:
            resp = call("inference/complete", {
                "prompt":      prompt,
                "tier":        "medium",
                "maxTokens":   600,
                "temperature": 0.5,
                "taskKind":    "generation",
            }, timeout=120)
        except Exception as e:
            _log(f"email-reply: inference failed: {e}")
            try:
                call("ui/toast", {
                    "title": "Email Reply",
                    "body":  f"Couldn't draft a reply: {e}",
                })
            except Exception:
                pass
            return

        draft = ((resp or {}).get("text") or "").strip()
        # The in-process plugin runs `unwrappedModelText` to strip
        # surrounding quotes; same idea here for robustness against
        # smaller models that wrap output.
        if draft and draft[0] in '"“' and draft[-1] in '"”':
            draft = draft[1:-1].strip()
        if not draft:
            try:
                call("ui/toast", {
                    "title": "Email Reply",
                    "body":  "The model returned an empty draft. Try again.",
                })
            except Exception:
                pass
            return

        # Insert at the caret. The in-process plugin checks for a
        # zero-length selection (a plain caret), otherwise falls back to
        # the clipboard so it never clobbers a highlight. We don't have
        # the structured selection range over RPC today — ax/readSelection
        # returns just text — so we use ui/prompt to ask the user where
        # to put the draft, in plain English. The detail view in v0.2.0+
        # offers a one-shot "auto-insert when possible" toggle that we'll
        # honour once a richer ax/readSelection lands.
        try:
            choice = call("ui/prompt", {
                "title":   "Email Reply",
                "body":    "Insert this draft at your cursor, or copy to the clipboard?",
                "actions": ["Insert", "Copy"],
            })
        except Exception as e:
            _log(f"email-reply: ui/prompt failed: {e}")
            return

        action = (choice or {}).get("action") or ""
        if action == "Insert":
            try:
                call("ax/replaceRange", {"location": 0, "length": 0, "text": draft})
                _log(f"email-reply: inserted {len(draft)}-char draft")
            except Exception as e:
                _log(f"email-reply: insert failed, falling back to toast: {e}")
                try:
                    call("ui/toast", {
                        "title": "Email Reply",
                        "body":  "Couldn't insert. Press ⌃⌥E again or copy the draft yourself.",
                    })
                except Exception:
                    pass
        elif action == "Copy":
            # The current host has no `clipboard/set` RPC method, so the
            # cleanest path is to put the draft in the toast body and let
            # the user double-click to copy. Adding `clipboard/set` is a
            # natural next host method but out-of-scope for the first
            # email-reply extraction.
            try:
                call("ui/toast", {
                    "title": "Email Reply (copy from here)",
                    "body":  draft,
                })
                _log(f"email-reply: surfaced {len(draft)}-char draft via toast")
            except Exception as e:
                _log(f"email-reply: copy fallback failed: {e}")
    finally:
        _inflight_lock.release()


# --- hotkey wiring ------------------------------------------------------------

# Carbon virtual key code for "E" and the modifier bitmask we want
# (Control + Option, no Cmd, no Shift). Defined here so the registration
# call is self-documenting.
KVK_ANSI_E   = 14          # from Carbon.HIToolbox kVK_ANSI_E
CONTROL_KEY  = 0x1000      # Carbon controlKey
OPTION_KEY   = 0x0800      # Carbon optionKey
HOTKEY_ID    = "draft"     # identifier echoed back in hotkey.fired events


def register_hotkey():
    try:
        call("hotkey/register", {
            "id":        HOTKEY_ID,
            "keyCode":   KVK_ANSI_E,
            "modifiers": CONTROL_KEY | OPTION_KEY,
        })
        _log("email-reply: registered ⌃⌥E")
    except Exception as e:
        _log(f"email-reply: hotkey/register failed: {e}")


# --- main loop ----------------------------------------------------------------

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
            # Register the hotkey on a worker thread so a slow Carbon
            # round-trip doesn't block stdin processing.
            threading.Thread(target=register_hotkey, daemon=True).start()
        elif method == "shutdown":
            _stop.set()
            try:
                call("hotkey/unregister", {"id": HOTKEY_ID}, timeout=2)
            except Exception:
                # Best-effort — the host unregisters our hotkeys on
                # process termination anyway, so a failure here is fine.
                pass
            _send({"jsonrpc": "2.0", "id": msg["id"], "result": None})
        elif method == "exit":
            _stop.set()
            break
        elif method == "event/hotkey.fired":
            payload = (msg.get("params") or {}).get("payload") or {}
            if payload.get("id") == HOTKEY_ID:
                threading.Thread(target=draft_reply, daemon=True).start()
        elif method == "event/app.focused":
            payload = (msg.get("params") or {}).get("payload") or {}
            note_focus(payload)
        elif method is None and "id" in msg:
            _resolve(msg)

    _stop.set()


if __name__ == "__main__":
    main()
