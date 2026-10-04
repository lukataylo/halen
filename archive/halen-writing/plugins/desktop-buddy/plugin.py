#!/usr/bin/env python3
"""Halen Desktop Buddy — out-of-process plugin.

A friendly Gemma-powered character that lives on the user's desktop. Press
⌃⌥B to focus and ask anything; if text is selected in the focused app the
buddy switches to a rewrite prompt. Reacts to typing tone by changing
expression. Nudges before upcoming calendar events.

This plugin is a bridge: it speaks JSON-RPC 2.0 over stdio to the Halen
host, and NDJSON over a child pipe to a Swift companion process that draws
the floating character window. The companion holds no host capabilities of
its own — every privileged call (inference, AX writes, calendar reads,
hotkey wiring) goes through here, then through the host.
"""
import sys
import os
import json
import time
import threading
import itertools
import subprocess
from collections import deque

# --- locations --------------------------------------------------------------

HERE = os.path.dirname(os.path.abspath(__file__))
# `build.sh` symlinks the release binary into ./bin/DesktopBuddy. Fall back
# to swift's default .build path when running from a fresh source tree.
_CANDIDATE_PATHS = [
    os.path.join(HERE, "bin", "DesktopBuddy"),
    os.path.join(HERE, "companion", ".build", "release", "DesktopBuddy"),
    os.path.join(HERE, "companion", ".build", "arm64-apple-macosx", "release", "DesktopBuddy"),
    os.path.join(HERE, "companion", ".build", "x86_64-apple-macosx", "release", "DesktopBuddy"),
]


def _find_companion():
    for path in _CANDIDATE_PATHS:
        if os.path.exists(path) and os.access(path, os.X_OK):
            return path
    return None


# --- hotkey constants -------------------------------------------------------
# Carbon virtual key codes / modifier flags; see plugins/README.md for the
# host's hotkey/register contract.
kVK_ANSI_B = 0x0B
controlKey = 0x1000
optionKey = 0x0800
shiftKey = 0x0200

FOCUS_HOTKEY_ID = "desktop-buddy.focus"
FOCUS_HOTKEY_MODS = controlKey | optionKey  # ⌃⌥B


# --- JSON-RPC plumbing (host side) ------------------------------------------

_ids = itertools.count(1)
_ids_lock = threading.Lock()
_host_out_lock = threading.Lock()
_pending = {}
_pending_lock = threading.Lock()
_stop = threading.Event()


def _host_send(msg):
    line = json.dumps(msg) + "\n"
    with _host_out_lock:
        sys.stdout.write(line)
        sys.stdout.flush()


def _log(text):
    sys.stderr.write(text + "\n")
    sys.stderr.flush()


def call(method, params, timeout=180):
    """Send a request to the host and block until the response arrives."""
    with _ids_lock:
        rid = next(_ids)
    event = threading.Event()
    slot = {}
    with _pending_lock:
        _pending[rid] = (event, slot)
    _host_send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
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


# --- companion process / NDJSON bridge --------------------------------------

_companion = None
_companion_lock = threading.Lock()


def companion_send(msg):
    """Send a one-line JSON message to the Swift companion."""
    with _companion_lock:
        proc = _companion
        if proc is None or proc.poll() is not None:
            return
        try:
            proc.stdin.write((json.dumps(msg) + "\n").encode("utf-8"))
            proc.stdin.flush()
        except (BrokenPipeError, OSError) as exc:
            _log(f"buddy: companion stdin write failed: {exc}")


def _companion_stdout_loop():
    proc = _companion
    if proc is None or proc.stdout is None:
        return
    for raw in proc.stdout:
        if _stop.is_set():
            break
        line = raw.decode("utf-8", errors="replace").strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            _log(f"buddy: companion sent non-JSON: {line[:120]}")
            continue
        handle_companion_event(msg)
    _log("buddy: companion stdout closed")


def _companion_stderr_loop():
    proc = _companion
    if proc is None or proc.stderr is None:
        return
    for raw in proc.stderr:
        line = raw.decode("utf-8", errors="replace").rstrip()
        if line:
            _log(f"buddy/companion: {line}")


def launch_companion():
    global _companion
    binary = _find_companion()
    if not binary:
        _log("buddy: companion binary not found. Run `./build.sh` in "
             f"{HERE} to build it. Looked at: {_CANDIDATE_PATHS}")
        return False
    env = {**os.environ, "DESKTOP_BUDDY_LOG": "1"}
    try:
        _companion = subprocess.Popen(
            [binary],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=HERE,
            env=env,
        )
    except OSError as exc:
        _log(f"buddy: failed to launch companion {binary}: {exc}")
        return False
    _log(f"buddy: companion launched (pid {_companion.pid}) from {binary}")
    threading.Thread(target=_companion_stdout_loop, daemon=True).start()
    threading.Thread(target=_companion_stderr_loop, daemon=True).start()
    return True


# --- companion event handlers -----------------------------------------------

def handle_companion_event(msg):
    """Events from the Swift companion: user clicked, submitted, dismissed."""
    kind = msg.get("type")
    if kind == "ready":
        companion_send({"type": "expression", "state": "neutral"})
    elif kind == "submit":
        text = (msg.get("text") or "").strip()
        mode = msg.get("mode") or "chat"
        if not text:
            return
        threading.Thread(target=handle_submit, args=(text, mode), daemon=True).start()
    elif kind == "clicked":
        companion_send({"type": "focus", "mode": detect_default_mode()})
    elif kind == "closed":
        companion_send({"type": "expression", "state": "neutral"})


def detect_default_mode():
    """If the focused app has a non-empty text selection, default to rewrite."""
    try:
        sel = call("ax/readSelection", {}, timeout=4) or {}
        if (sel.get("length") or 0) > 0 and (sel.get("text") or "").strip():
            return "rewrite"
    except Exception:
        pass
    return "chat"


# --- submit handling --------------------------------------------------------

def handle_submit(instruction, mode):
    companion_send({"type": "expression", "state": "thinking"})
    try:
        if mode == "rewrite":
            do_rewrite(instruction)
        else:
            do_chat(instruction)
    except Exception as exc:
        _log(f"buddy: submit failed ({mode}): {exc}")
        companion_send({"type": "showReply",
                        "text": f"Couldn't do that: {exc}", "error": True})
    finally:
        companion_send({"type": "expression", "state": "neutral"})


def do_chat(question):
    prompt = (
        "You are a concise, friendly desktop assistant living as a little "
        "character on the user's screen. Answer in under 120 words. Plain "
        "prose — no markdown, no preamble, no sign-off.\n\n"
        f"Question: {question}"
    )
    result = call("inference/complete", {
        "prompt": prompt,
        "tier": "medium",
        "maxTokens": 300,
        "temperature": 0.5,
        "taskKind": "generation",
    })
    text = ((result or {}).get("text") or "").strip()
    companion_send({"type": "showReply", "text": text or "…"})


def do_rewrite(instruction):
    sel = call("ax/readSelection", {}) or {}
    selected = sel.get("text") or ""
    location = sel.get("location")
    length = sel.get("length") or 0
    if not selected.strip() or location is None or length <= 0:
        companion_send({
            "type": "showReply",
            "text": "Select some text in another app first, then ask me to rewrite it.",
            "error": True,
        })
        return
    prompt = (
        "Rewrite the text below following the instruction. Output ONLY the "
        "rewritten text — no quotes, no preamble, no explanation.\n\n"
        f"Instruction: {instruction or 'make it clearer and a little warmer'}\n\n"
        f"Text:\n{selected}"
    )
    result = call("inference/complete", {
        "prompt": prompt,
        "tier": "medium",
        "maxTokens": min(2048, max(256, len(selected) * 2)),
        "temperature": 0.3,
        "taskKind": "generation",
    })
    rewritten = ((result or {}).get("text") or "").strip()
    if not rewritten:
        companion_send({"type": "showReply", "text": "(empty rewrite)", "error": True})
        return
    try:
        call("ax/replaceRange", {
            "location": location, "length": length, "text": rewritten,
        })
        companion_send({"type": "showReply", "text": "Rewritten ✓"})
    except Exception as exc:
        companion_send({
            "type": "showReply",
            "text": f"Couldn't replace the selection ({exc}). Here's the rewrite:\n\n{rewritten}",
            "error": True,
        })


# --- tone reaction ----------------------------------------------------------

TONE_DEBOUNCE_SEC = 2.5
TONE_MIN_LENGTH = 60
_tone_timer = None
_tone_timer_lock = threading.Lock()
_tone_history = deque(maxlen=5)


def schedule_tone(text):
    global _tone_timer
    if len(text) < TONE_MIN_LENGTH:
        return
    with _tone_timer_lock:
        if _tone_timer is not None:
            _tone_timer.cancel()
        _tone_timer = threading.Timer(TONE_DEBOUNCE_SEC, classify_tone, args=(text,))
        _tone_timer.daemon = True
        _tone_timer.start()


def classify_tone(text):
    prompt = (
        'Classify the emotional tone of the following writing. Reply with '
        'EXACTLY one lowercase word: "happy", "neutral", or "frustrated".\n\n'
        f'Text: """{text[:1200]}"""'
    )
    try:
        result = call("inference/complete", {
            "prompt": prompt,
            "tier": "small",
            "maxTokens": 8,
            "temperature": 0.1,
            "taskKind": "classification",
        })
    except Exception as exc:
        _log(f"buddy: tone classify failed: {exc}")
        return
    answer = ((result or {}).get("text") or "").strip().lower()
    if answer.startswith("happy"):
        state = "happy"
    elif answer.startswith("frustrated") or answer.startswith("angry"):
        state = "worried"
    else:
        state = "neutral"
    _tone_history.append(state)
    # Only switch the face when two of the last three classifications agree.
    # Single-shot misreads are common; this kills the twitch.
    recent = list(_tone_history)[-3:]
    if recent.count(state) >= 2:
        companion_send({"type": "expression", "state": state, "ttlMs": 12000})


# --- calendar nudges --------------------------------------------------------

CAL_POLL_SECONDS = 240
NUDGE_WINDOW_MIN = (3, 10)  # nudge between 3 and 10 min before the event
_nudged = set()


def calendar_loop():
    if not _stop.wait(20):
        _safe(check_calendar, "calendar poll")
    while not _stop.wait(CAL_POLL_SECONDS):
        _safe(check_calendar, "calendar poll")


def check_calendar():
    result = call("calendar/upcomingEvents", {"withinHours": 1, "max": 10})
    events = (result or {}).get("events", [])
    now = time.time()
    for event in events:
        eid = event.get("id")
        if not eid or eid in _nudged:
            continue
        minutes_away = (event.get("start", 0) - now) / 60
        lo, hi = NUDGE_WINDOW_MIN
        if not (lo <= minutes_away <= hi):
            continue
        _nudged.add(eid)
        title = event.get("title") or "your next meeting"
        companion_send({
            "type": "say",
            "text": f'"{title}" in {int(round(minutes_away))} min.',
            "ttlMs": 14000,
        })
        companion_send({"type": "expression", "state": "thinking", "ttlMs": 8000})


def _safe(fn, label):
    try:
        fn()
    except Exception as exc:
        _log(f"buddy: {label} failed: {exc}")


# --- host event dispatch ----------------------------------------------------

def on_hotkey(payload):
    if payload.get("id") == FOCUS_HOTKEY_ID:
        companion_send({"type": "focus", "mode": detect_default_mode()})


def register_focus_hotkey():
    try:
        call("hotkey/register", {
            "id": FOCUS_HOTKEY_ID,
            "keyCode": kVK_ANSI_B,
            "modifiers": FOCUS_HOTKEY_MODS,
        })
        _log("buddy: registered ⌃⌥B focus hotkey")
    except Exception as exc:
        _log(f"buddy: hotkey/register failed: {exc}")


# --- main loop --------------------------------------------------------------

def shutdown_companion():
    proc = _companion
    if proc is None or proc.poll() is not None:
        return
    try:
        companion_send({"type": "shutdown"})
    except Exception:
        pass
    try:
        if proc.stdin:
            proc.stdin.close()
    except Exception:
        pass
    try:
        proc.terminate()
        proc.wait(timeout=2)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


def main():
    started = False
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
            _host_send({"jsonrpc": "2.0", "id": msg["id"],
                        "result": {"capabilities": {}}})
        elif method == "notifications/initialized":
            if not started:
                started = True
                if launch_companion():
                    register_focus_hotkey()
                    threading.Thread(target=calendar_loop, daemon=True).start()
        elif method == "shutdown":
            _stop.set()
            shutdown_companion()
            _host_send({"jsonrpc": "2.0", "id": msg["id"], "result": None})
        elif method == "exit":
            _stop.set()
            shutdown_companion()
            break
        elif method == "event/text.pause":
            payload = (msg.get("params") or {}).get("payload") or {}
            schedule_tone(payload.get("text") or "")
        elif method == "event/hotkey.fired":
            on_hotkey((msg.get("params") or {}).get("payload") or {})
        elif method is None and "id" in msg:
            _resolve(msg)

    _stop.set()
    shutdown_companion()


if __name__ == "__main__":
    main()
