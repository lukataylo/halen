#!/usr/bin/env python3
"""Halen Meeting Prep — out-of-process plugin.

Polls the host's calendar capability; ~15 minutes before each upcoming event
it asks the host's local model for a 5-bullet briefing and posts a system
notification. Every privileged operation (reading the calendar, running
inference, posting the notification) is done by the host over JSON-RPC — this
plugin holds no macOS entitlements of its own and links no system frameworks.

Protocol: JSON-RPC 2.0, newline-delimited. stdin = host -> plugin,
stdout = plugin -> host, stderr = log (forwarded into Halen's unified log).
"""
import sys
import json
import time
import threading
import itertools

# --- plumbing ---------------------------------------------------------------

_ids = itertools.count(1)
_ids_lock = threading.Lock()
_out_lock = threading.Lock()           # serialises stdout writes
_pending = {}                          # request id -> (Event, result slot)
_pending_lock = threading.Lock()
_stop = threading.Event()
_briefed = set()                       # per-occurrence ids briefed this session

POLL_SECONDS = 240                     # re-check the calendar every 4 minutes


def _send(msg):
    line = json.dumps(msg) + "\n"
    with _out_lock:
        sys.stdout.write(line)
        sys.stdout.flush()


def _log(text):
    # stderr is forwarded into Halen's unified log (already timestamped there).
    sys.stderr.write(text + "\n")
    sys.stderr.flush()


def call(method, params, timeout=120):
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
    """A response to one of our outbound requests has arrived on stdin."""
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


# --- meeting-prep logic ------------------------------------------------------

def brief_event(event):
    title = event.get("title", "Untitled")
    attendees = ", ".join(event.get("attendees", [])) or "(none listed)"
    notes = (event.get("notes") or "").strip() or "(none)"
    prompt = (
        "Write a 5-bullet meeting briefing. Output only the bullets, no "
        "preamble or trailing text.\n"
        "Cover: likely agenda; questions to ask; things to bring up; prep "
        "needed; a tone cue.\n\n"
        f"Meeting: {title}\nAttendees: {attendees}\nDescription: {notes}"
    )
    try:
        result = call("inference/complete", {
            "prompt": prompt, "tier": "medium", "maxTokens": 400,
            "temperature": 0.4, "taskKind": "generation",
        }, timeout=180)
    except Exception as exc:
        _log(f"meeting-prep: briefing failed for '{title}': {exc}")
        return
    briefing = (result.get("text") or "").strip() if result else ""
    if not briefing:
        _log(f"meeting-prep: empty briefing for '{title}'")
        return
    call("ui/toast", {"title": f"Prep — {title}", "body": briefing})
    _log(f"meeting-prep: briefed '{title}'")


def check_calendar():
    """Brief any soon-starting event we haven't briefed yet."""
    result = call("calendar/upcomingEvents", {"withinHours": 1, "max": 20})
    events = (result or {}).get("events", [])
    # Heartbeat — proves the calendar round-trip and gives an operational
    # trace in Halen's unified log even when there's nothing to brief.
    _log(f"meeting-prep: polled calendar — {len(events)} event(s) in the next hour")
    now = time.time()
    for event in events:
        eid = event.get("id")
        minutes_away = (event.get("start", 0) - now) / 60
        # 2-17 min window: enough lead time to read it, not so early it's stale.
        if not (2 <= minutes_away <= 17) or eid in _briefed:
            continue
        _briefed.add(eid)
        brief_event(event)


def poll_loop():
    # First check shortly after launch, then on the interval.
    if not _stop.wait(15):
        _safe_check()
    while not _stop.wait(POLL_SECONDS):
        _safe_check()


def _safe_check():
    try:
        check_calendar()
    except Exception as exc:
        _log(f"meeting-prep: calendar poll failed: {exc}")


# --- main loop ---------------------------------------------------------------

def main():
    poller = None
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
            poller = threading.Thread(target=poll_loop, daemon=True)
            poller.start()
        elif method == "shutdown":
            _stop.set()
            _send({"jsonrpc": "2.0", "id": msg["id"], "result": None})
        elif method == "exit":
            _stop.set()
            break
        elif method is None and "id" in msg:
            # A response to a request we sent.
            _resolve(msg)
        # event/* notifications are ignored — Meeting Prep is poll-driven.

    _stop.set()


if __name__ == "__main__":
    main()
