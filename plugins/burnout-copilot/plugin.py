#!/usr/bin/env python3
"""Halen Burnout Copilot — out-of-process plugin.

Watches three signals and suggests a break when at least two trip:
  A. distraction-app time   — focus segments from `app.focused` events
  B. recent writing tone    — yes/no tone classification of `text.pause` text
  C. calendar density       — events in the next 4 h (polled)

On a trip it raises a `ui/prompt`; accepting creates a 10-minute calendar
break and fires the optional "Halen Focus" Shortcut. Every privileged
operation goes through the host over JSON-RPC — this plugin holds no macOS
entitlements of its own.
"""
import sys
import json
import time
import subprocess
import threading
import itertools
from collections import deque

# --- JSON-RPC plumbing (shared shape with the meeting-prep plugin) ----------

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
    """Send a request to the host and block until the response arrives."""
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


# --- tunables ----------------------------------------------------------------

DISTRACTION_BUNDLES = {
    "com.tinyspeck.slackmacgap",   # Slack
    "com.hnc.Discord",             # Discord
    "com.twitter.twitter-mac",     # Twitter
    "com.atebits.Tweetie2",        # Twitterrific
    "ru.keepcoder.Telegram",       # Telegram
    "com.reddit.reddit",
    "com.zhiliaoapp.musically",    # TikTok
    "com.facebook.archon",         # Messenger
    "com.colliderli.iina",         # streaming
    "com.netflix.Netflix",
}
DISTRACTION_WINDOW = 2 * 60 * 60     # rolling 2 h
DISTRACTION_TRIP_MINUTES = 90
TONE_WINDOW = 10                     # last N classified paragraphs
TONE_TRIP_SHARP = 3
TONE_DEBOUNCE = 2.5                  # settle after typing stops
TONE_MIN_LENGTH = 60
CALENDAR_TRIP_EVENTS = 3
CALENDAR_POLL_SECONDS = 300
COOLDOWN_SECONDS = 30 * 60           # don't re-nag for 30 min after a prompt

# --- shared signal state (guarded by `_state_lock`) -------------------------

_state_lock = threading.Lock()
_segments = []                       # (bundle_id, start_epoch, end_epoch)
_current = {"bundle": None, "start": 0.0}
_tone = deque(maxlen=TONE_WINDOW)    # bools — True == sharp
_calendar = {"events": 0, "back_to_back": False}
_cooldown_until = 0.0
_prompt_active = False
_eval_event = threading.Event()      # set to ask the evaluator to run


def note_focus(bundle_id, now=None):
    now = now or time.time()
    with _state_lock:
        prev, start = _current["bundle"], _current["start"]
        if prev is not None:
            _segments.append((prev, start, now))
        _current["bundle"] = bundle_id
        _current["start"] = now
        cutoff = now - DISTRACTION_WINDOW
        _segments[:] = [s for s in _segments if s[2] >= cutoff]


def distraction_minutes(now=None):
    now = now or time.time()
    cutoff = now - DISTRACTION_WINDOW
    total = 0.0
    with _state_lock:
        for bundle, start, end in _segments:
            if bundle in DISTRACTION_BUNDLES:
                total += max(0.0, min(end, now) - max(start, cutoff))
        cur, cstart = _current["bundle"], _current["start"]
        if cur in DISTRACTION_BUNDLES:
            total += max(0.0, now - max(cstart, cutoff))
    return int(total / 60)


# --- signal B: tone ----------------------------------------------------------

_tone_timer = None
_tone_timer_lock = threading.Lock()


def schedule_tone(text):
    """Debounce: classify only once typing has settled for TONE_DEBOUNCE."""
    global _tone_timer
    if len(text) < TONE_MIN_LENGTH:
        return
    with _tone_timer_lock:
        if _tone_timer is not None:
            _tone_timer.cancel()
        _tone_timer = threading.Timer(TONE_DEBOUNCE, classify_tone, args=(text,))
        _tone_timer.daemon = True
        _tone_timer.start()


def classify_tone(text):
    prompt = (
        'Is the tone of the following text irritated, sharp, or hostile? '
        'Reply with only "yes" or "no", lowercase.\n\n'
        f'Text: """{text}"""'
    )
    try:
        result = call("inference/complete", {
            "prompt": prompt, "tier": "small", "maxTokens": 16,
            "temperature": 0.1, "taskKind": "classification",
        })
    except Exception as exc:
        _log(f"burnout: tone classify failed: {exc}")
        return
    answer = ((result or {}).get("text") or "").strip().lower()
    sharp = answer.startswith("yes")
    with _state_lock:
        _tone.append(sharp)
    _eval_event.set()


# --- signal C: calendar ------------------------------------------------------

def poll_calendar():
    result = call("calendar/upcomingEvents", {"withinHours": 4, "max": 30})
    events = sorted((result or {}).get("events", []), key=lambda e: e.get("start", 0))
    now = time.time()
    # Back-to-back: two events in the next 30 min with < 5 min between them.
    soon = [e for e in events if e.get("start", 0) < now + 30 * 60]
    back_to_back = any(
        soon[i].get("start", 0) - soon[i - 1].get("end", 0) < 5 * 60
        for i in range(1, len(soon))
    )
    with _state_lock:
        _calendar["events"] = len(events)
        _calendar["back_to_back"] = back_to_back
    _log(f"burnout: calendar — {len(events)} event(s) in 4 h, "
         f"back-to-back={back_to_back}")


def calendar_loop():
    if not _stop.wait(20):
        _safe(poll_calendar, "calendar poll")
        _eval_event.set()
    while not _stop.wait(CALENDAR_POLL_SECONDS):
        _safe(poll_calendar, "calendar poll")
        _eval_event.set()


def _safe(fn, label):
    try:
        fn()
    except Exception as exc:
        _log(f"burnout: {label} failed: {exc}")


# --- evaluation --------------------------------------------------------------

def evaluate():
    """Check the three signals; raise the break prompt if >= 2 trip."""
    global _cooldown_until, _prompt_active
    now = time.time()
    with _state_lock:
        if _prompt_active or now < _cooldown_until:
            return
        mins = None  # computed below without the lock to avoid re-entry
        sharp = sum(_tone)
        events = _calendar["events"]
        back_to_back = _calendar["back_to_back"]
    mins = distraction_minutes(now)

    signal_a = mins >= DISTRACTION_TRIP_MINUTES
    signal_b = sharp >= TONE_TRIP_SHARP
    signal_c = events >= CALENDAR_TRIP_EVENTS or back_to_back
    tripped = [signal_a, signal_b, signal_c]
    if sum(tripped) < 2:
        return

    reasons = []
    if signal_a:
        reasons.append(f"{mins} min in distraction apps")
    if signal_b:
        reasons.append("recent writing reads sharp")
    if signal_c:
        reasons.append("back-to-back meetings soon" if back_to_back
                        else f"{events} meetings in the next 4 h")
    body = "You've been at it a while — " + " · ".join(reasons) + ". Take 10?"

    with _state_lock:
        _prompt_active = True
    try:
        result = call("ui/prompt", {
            "title": "Burnout Copilot",
            "body": body,
            "actions": ["Take a break", "Not now"],
        }, timeout=360)
        action = (result or {}).get("action")
        if action == "Take a break":
            accept_break()
    finally:
        with _state_lock:
            _prompt_active = False
            _cooldown_until = time.time() + COOLDOWN_SECONDS


def accept_break():
    # 10-minute break event, starting now.
    try:
        call("calendar/createEvent", {
            "title": "\U0001F33F Halen break",
            "start": time.time(),
            "durationMinutes": 10,
        })
        _log("burnout: created Halen break event")
    except Exception as exc:
        _log(f"burnout: createEvent failed: {exc}")
    # Optional "Halen Focus" Shortcut — silent if it doesn't exist. The plugin
    # can spawn its own subprocess; no host capability needed.
    try:
        subprocess.run(
            ["/usr/bin/osascript", "-e",
             'tell application "Shortcuts Events" to run shortcut "Halen Focus"'],
            timeout=15, capture_output=True)
    except Exception as exc:
        _log(f"burnout: Shortcuts trigger skipped ({exc})")


def evaluator_loop():
    """Single owner of evaluate() — so two threads can't double-prompt."""
    while not _stop.is_set():
        # Wake on a signal, or every 5 min as a heartbeat.
        _eval_event.wait(timeout=300)
        _eval_event.clear()
        if _stop.is_set():
            break
        _safe(evaluate, "evaluate")


# --- main loop ---------------------------------------------------------------

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
            _send({"jsonrpc": "2.0", "id": msg["id"],
                   "result": {"capabilities": {}}})
        elif method == "notifications/initialized":
            if not started:
                started = True
                for target in (calendar_loop, evaluator_loop):
                    threading.Thread(target=target, daemon=True).start()
        elif method == "shutdown":
            _stop.set()
            _eval_event.set()
            _send({"jsonrpc": "2.0", "id": msg["id"], "result": None})
        elif method == "exit":
            _stop.set()
            _eval_event.set()
            break
        elif method == "event/app.focused":
            payload = (msg.get("params") or {}).get("payload") or {}
            bundle = payload.get("appBundleId")
            if bundle:
                note_focus(bundle)
                _eval_event.set()
        elif method == "event/text.pause":
            payload = (msg.get("params") or {}).get("payload") or {}
            schedule_tone(payload.get("text") or "")
        elif method is None and "id" in msg:
            _resolve(msg)

    _stop.set()
    _eval_event.set()


if __name__ == "__main__":
    main()
