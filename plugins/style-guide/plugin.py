#!/usr/bin/env python3
"""Halen Personal Style Guide — out-of-process plugin.

Pure rule engine. Holds the user's banned-word -> preferred-word pairs and
"never use X" prohibitions in a JSON file under $HALEN_PLUGIN_DIR; scans
each `text.pause` event's paragraph for matches; surfaces matches via
`ui/prompt` and applies one-tap replacements via `ax/replaceRange`.

Mirrors the in-process Swift implementation that shipped through v0.2.0
(StyleGuide.swift, StyleRulesStore.swift) — same defaults, same matching
semantics (case-insensitive, word-boundary aware for literal rules,
NSRegularExpression-compatible for regex rules), same per-paragraph
behaviour (at most one match per scan).

Every privileged operation goes through the host over JSON-RPC; this
plugin holds no macOS entitlements of its own.
"""
import sys
import os
import re
import json
import time
import threading
import itertools
import hashlib

# --- JSON-RPC plumbing (shared shape with the burnout-copilot plugin) -------

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


# --- rules store --------------------------------------------------------------

# Storage path inside $HALEN_PLUGIN_DIR (the host sets this env var on
# spawn; falls back to the directory next to this script if not present,
# which keeps the plugin runnable for ad-hoc testing).
_PLUGIN_DIR = os.environ.get("HALEN_PLUGIN_DIR") or os.path.dirname(os.path.abspath(__file__))
_RULES_PATH = os.path.join(_PLUGIN_DIR, "rules.json")

# Default rules — identical to the in-process Swift implementation's
# `StyleRulesStore.builtins`. Anything the user adds layers on top.
_BUILTINS = [
    {"id": "utilize",       "banned": "utilize",      "preferred": "use",        "enabled": True, "builtin": True, "kind": "literal"},
    {"id": "very_unique",   "banned": "very unique",  "preferred": "unique",     "enabled": True, "builtin": True, "kind": "literal"},
    {"id": "irregardless",  "banned": "irregardless", "preferred": "regardless", "enabled": True, "builtin": True, "kind": "literal"},
]

_rules_lock = threading.Lock()
_rules = []   # populated in load_rules()


def load_rules():
    """Read rules.json if present, merge any missing builtins, persist."""
    global _rules
    loaded = []
    if os.path.exists(_RULES_PATH):
        try:
            with open(_RULES_PATH, "r", encoding="utf-8") as f:
                loaded = json.load(f)
        except Exception as e:
            _log(f"style-guide: rules.json unreadable ({e}); starting from defaults")
            loaded = []

    # Merge defaults — same semantics as the Swift store's `ensureDefaults`:
    # any builtin not already in the file is appended. Lets future builtin
    # additions ship without resetting the user's own rules.
    existing = {r.get("id") for r in loaded}
    changed = False
    for b in _BUILTINS:
        if b["id"] not in existing:
            loaded.append(dict(b))
            changed = True

    # Normalise: ensure every rule carries the kind field (older payloads
    # from the in-process plugin shipped with no "kind", defaulting to
    # literal). Same forward-compat dance the Swift Decodable init does.
    for r in loaded:
        r.setdefault("kind", "literal")
        r.setdefault("enabled", True)
        r.setdefault("builtin", False)

    with _rules_lock:
        _rules = loaded
    if changed:
        save_rules()
    _log(f"style-guide: loaded {len(_rules)} rule(s)")


def save_rules():
    try:
        os.makedirs(_PLUGIN_DIR, exist_ok=True)
        tmp = _RULES_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(_rules, f, indent=2, sort_keys=True)
        os.replace(tmp, _RULES_PATH)
    except Exception as e:
        _log(f"style-guide: failed to save rules.json: {e}")


def enabled_rules():
    with _rules_lock:
        return [r for r in _rules if r.get("enabled", True)]


# --- scanning -----------------------------------------------------------------

# Hash-based dedup so we don't re-prompt for the same paragraph after the
# user dismisses or fixes. Bounded LRU keeps memory flat.
_seen_hashes = []
_seen_max = 256
_seen_lock = threading.Lock()


def _paragraph_around(text, caret_offset):
    """Return the paragraph (line, really) the caret sits inside.

    Mirrors `paragraphAroundCaret` in Swift: scan back from caret_offset
    to the prior `\\n` (or 0); forward to the next `\\n` (or end).
    """
    if not text:
        return ""
    n = len(text)
    co = max(0, min(caret_offset, n))
    start = text.rfind("\n", 0, co)
    start = start + 1 if start >= 0 else 0
    end = text.find("\n", co)
    if end < 0:
        end = n
    return text[start:end]


def _word_range(term, text):
    """First word-boundary-respecting occurrence of `term` in `text`.

    Matches the semantics of `StyleRulesStore.wordRange(of:in:)` in Swift:
    case-insensitive substring match, but only counted when neither the
    character immediately before nor immediately after is a letter.
    Returns (start, end) indices, or None.
    """
    if not term:
        return None
    lower_text = text.lower()
    lower_term = term.lower()
    n = len(text)
    tn = len(term)
    start = 0
    while start < n:
        idx = lower_text.find(lower_term, start)
        if idx < 0:
            return None
        before = text[idx - 1] if idx > 0 else ""
        after_idx = idx + tn
        after = text[after_idx] if after_idx < n else ""
        if not before.isalpha() and not after.isalpha():
            return (idx, after_idx)
        start = idx + max(1, tn)
    return None


def _regex_range(pattern, text):
    """First case-insensitive regex match of `pattern` in `text`, or None.

    Returns (start, end). A bad pattern returns None (the in-process
    implementation validated at add time; we degrade gracefully if a
    hand-edited rules.json slips an invalid one through).
    """
    try:
        m = re.search(pattern, text, re.IGNORECASE)
    except re.error:
        return None
    if not m:
        return None
    return (m.start(), m.end())


def scan(paragraph):
    """Return the first matching rule for `paragraph`, or None.

    The in-process implementation returns *all* matches and shows them
    together in a popover. The ui/prompt RPC is blocking and per-call, so
    we surface one rule at a time — the user can iterate by typing past
    the first match and triggering the scan again.
    """
    for rule in enabled_rules():
        kind = rule.get("kind", "literal")
        if kind == "literal":
            r = _word_range(rule.get("banned", ""), paragraph)
        elif kind == "regex":
            r = _regex_range(rule.get("banned", ""), paragraph)
        else:
            continue
        if r:
            return (rule, paragraph[r[0]:r[1]], r)
    return None


def _hash(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _mark_seen(paragraph_hash):
    with _seen_lock:
        if paragraph_hash in _seen_hashes:
            # LRU touch — move to back.
            _seen_hashes.remove(paragraph_hash)
            _seen_hashes.append(paragraph_hash)
            return True   # already seen
        _seen_hashes.append(paragraph_hash)
        if len(_seen_hashes) > _seen_max:
            _seen_hashes.pop(0)
        return False


# --- event handling -----------------------------------------------------------

# Serialise prompts so two text.pause events back-to-back don't race two
# ui/prompt calls (which would stack as two system dialogs).
_prompt_lock = threading.Lock()


def handle_text_pause(payload):
    text = payload.get("text") or ""
    caret = int(payload.get("caretOffset") or 0)
    paragraph = _paragraph_around(text, caret)
    # Cheap gate — paragraphs need at least a few words to be worth
    # scanning. The in-process plugin uses 12 chars.
    if len(paragraph) < 12:
        return

    # ui/prompt is blocking; if a previous prompt is still up we skip
    # rather than queueing. Returning fast keeps the host's event push
    # responsive.
    if not _prompt_lock.acquire(blocking=False):
        return
    try:
        h = _hash(paragraph)
        if _mark_seen(h):
            return
        result = scan(paragraph)
        if not result:
            return
        rule, matched_text, _range = result
        _show_prompt(rule, matched_text)
    finally:
        _prompt_lock.release()


def _show_prompt(rule, matched_text):
    """Ask the host to surface a prompt, then act on the user's choice."""
    preferred = (rule.get("preferred") or "").strip()
    if preferred:
        title = f"Style: “{matched_text}”"
        body  = f"Replace with “{preferred}”?"
        actions = ["Replace", "Skip"]
    else:
        # Pure prohibition — no preferred term to swap in.
        title = f"Style: avoid “{matched_text}”"
        body  = "Your style guide flags this term."
        actions = ["OK"]

    try:
        resp = call("ui/prompt", {
            "title": title,
            "body": body,
            "actions": actions,
        })
    except Exception as e:
        _log(f"style-guide: ui/prompt failed: {e}")
        return

    chosen = (resp or {}).get("action")
    if chosen != "Replace":
        return

    # Replace path: re-read the focused field so we can target the right
    # range even if the user kept typing while the prompt was up. Same
    # logic as the in-process plugin's `replace(rule:)`.
    try:
        selection = call("ax/readSelection", {})
    except Exception as e:
        _log(f"style-guide: ax/readSelection failed: {e}")
        return
    field_text = (selection or {}).get("text") or ""
    if not field_text:
        _log("style-guide: no focused text — skipping replace")
        return

    kind = rule.get("kind", "literal")
    if kind == "literal":
        r = _word_range(rule.get("banned", ""), field_text)
    else:
        r = _regex_range(rule.get("banned", ""), field_text)
    if not r:
        _log(f"style-guide: \"{rule.get('banned')}\" no longer in field — skipping replace")
        return

    try:
        call("ax/replaceRange", {
            "location": r[0],
            "length":   r[1] - r[0],
            "text":     preferred,
        })
        _log(f"style-guide: replaced \"{rule.get('banned')}\" -> \"{preferred}\"")
    except Exception as e:
        _log(f"style-guide: ax/replaceRange failed: {e}")


# --- main loop ----------------------------------------------------------------

def main():
    load_rules()

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
            # Nothing to start — handlers are purely event-driven.
            pass
        elif method == "shutdown":
            _stop.set()
            _send({"jsonrpc": "2.0", "id": msg["id"], "result": None})
        elif method == "exit":
            _stop.set()
            break
        elif method == "event/text.pause":
            payload = (msg.get("params") or {}).get("payload") or {}
            # Each event runs on its own short-lived thread so the main
            # stdin loop never blocks on the user's ui/prompt response.
            threading.Thread(
                target=handle_text_pause, args=(payload,), daemon=True
            ).start()
        elif method is None and "id" in msg:
            _resolve(msg)

    _stop.set()


if __name__ == "__main__":
    main()
