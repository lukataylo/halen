#!/usr/bin/env python3
"""Halen Reasoning Compactor — out-of-process plugin for developers.

Compacts verbose LLM "thinking" — chain-of-thought / reasoning traces — using
Halen's *local* model, so a developer can keep the load-bearing steps and the
final answer while dropping the filler that reasoning models pad their output
with. Works with the reasoning from any LLM (Claude, GPT, Gemini, DeepSeek,
local Qwen/Llama …) because it operates on whatever text is in front of you,
not on any one provider's API.

Two ways in:

  • Hotkey  ⌃⌥K   — compact the current selection. Reads the selection over
    the host's accessibility bridge, runs the compaction pass on-device, and
    drops the result on the clipboard. A toast reports the token savings; you
    press ⌘V to paste it back. Clipboard rather than in-place because reasoning
    traces live in browser chats, terminals and Electron editors where direct
    accessibility writes are unreliable (the host itself falls back to paste
    there) — copy-and-paste is the one mechanism that works everywhere.

  • Background — while it runs it watches focused text fields (`text.pause`).
    When a long, redundant reasoning trace settles in a field it posts a
    one-off nudge with the tokens you'd save by compacting it. Non-destructive:
    it never rewrites your text on its own, it only points at the opportunity.

The compaction strategy follows the 2025 chain-of-thought-compression
literature (Alibaba's step-entropy work and TokenSkip, EMNLP 2025): keep the
high-information reasoning steps, prune the low-information connective filler,
and preserve the conclusion verbatim. See README.md for the citations.

Every privileged operation (reading the selection, running inference, posting
the notification) goes through the host over JSON-RPC — this plugin holds no
macOS entitlements of its own and links no system frameworks. Setting the
clipboard uses /usr/bin/pbcopy, a subprocess the plugin spawns itself (same
pattern Burnout Copilot uses for its Shortcuts trigger).

Protocol: JSON-RPC 2.0, newline-delimited. stdin = host -> plugin,
stdout = plugin -> host, stderr = log (forwarded into Halen's unified log).
"""
import sys
import json
import time
import hashlib
import threading
import itertools
import subprocess

# --- JSON-RPC plumbing (shared shape with meeting-prep / burnout-copilot) ----

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
    """Send a request to the host and block until the response arrives.

    Must be called off the stdin-reading thread — the response is delivered by
    `_resolve` from that loop, so a `call()` on the main thread would deadlock.
    """
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

# ⌃⌥K. Carbon virtual key code for `K` is 40 (kVK_ANSI_K); modifier bitmask is
# controlKey (0x1000) | optionKey (0x800) = 0x1800.
HOTKEY_ID = "reasoning-compactor.compact"
HOTKEY_KEYCODE = 40
HOTKEY_MODIFIERS = 0x1000 | 0x800

# A reasoning trace has to be at least this long before compaction is worth a
# round-trip. ~4 chars per token, so 480 chars ≈ 120 tokens.
MIN_CHARS = 480
# Background nudge thresholds: only point at clearly-bloated traces, and only
# when the estimated saving clears a floor worth interrupting for.
NUDGE_MIN_CHARS = 900
NUDGE_MIN_SAVED_TOKENS = 80
NUDGE_DEBOUNCE = 2.0           # let typing settle before classifying a field
NUDGE_COOLDOWN = 8 * 60        # don't re-nag for the same field this often
# Aim to keep ~45% of the tokens — in line with the ~40% reduction TokenSkip
# reports on GSM8K at <0.4% accuracy loss. The model trims to the redundancy it
# actually finds; this is the target, not a hard cut.
TARGET_KEEP_RATIO = 0.45

# --- shared state ------------------------------------------------------------

_state_lock = threading.Lock()
_busy = threading.Lock()           # one compaction interaction at a time
_nudge_timer = None
_nudge_timer_lock = threading.Lock()
_recent_nudges = {}                # text-hash -> epoch of last nudge
_session_saved = 0                 # running total of tokens saved this session
_session_runs = 0


# --- token estimation --------------------------------------------------------

def estimate_tokens(text):
    """Rough token count. ~4 chars/token is the usual back-of-envelope for
    English prose and code; good enough to report savings and size requests."""
    return max(1, round(len(text) / 4))


# --- reasoning detection -----------------------------------------------------

# Lower-cased substrings that show up in step-by-step "thinking" but rarely in
# finished prose. Two or more distinct hits in a long block ⇒ a reasoning trace.
_MARKERS = (
    "<think>", "</think>", "let me", "let's", "first,", "firstly",
    "step 1", "step 2", "step-by-step", "wait,", "hmm", "okay,", "ok,",
    "therefore", "thus,", "so we", "so the", "we need", "we have", "i need to",
    "i should", "reconsider", "on second thought", "but wait", "alternatively",
    "actually,", "to summarize", "in summary", "the answer is", "final answer",
    "chain of thought", "reasoning:",
)


def reasoning_signal(text):
    """How many distinct reasoning markers appear (case-insensitive)."""
    low = text.lower()
    hits = sum(1 for m in _MARKERS if m in low)
    # Numbered scaffolding ("1." … "4.") is a strong signal on its own.
    numbered = sum(1 for n in range(1, 8) if f"\n{n}." in low or low.startswith(f"{n}."))
    if numbered >= 3:
        hits += 1
    return hits


def looks_like_reasoning(text, min_chars=MIN_CHARS):
    return len(text) >= min_chars and reasoning_signal(text) >= 2


# --- compaction --------------------------------------------------------------

def build_prompt(text):
    target = max(1, round(estimate_tokens(text) * TARGET_KEEP_RATIO))
    return (
        "You compress an LLM's chain-of-thought reasoning. Rewrite the "
        "reasoning below so it is much shorter while staying a faithful, "
        "verifiable trace of the SAME logic.\n\n"
        "Rules:\n"
        "- Keep every load-bearing step: the facts, equations, decisions and "
        "intermediate results the conclusion depends on.\n"
        "- Drop low-information filler: self-talk, restatements, hedging, "
        '"let me think", "wait", "okay", second-guessing that goes nowhere, '
        "and anything that does not change the outcome.\n"
        "- Preserve the final answer / conclusion exactly.\n"
        "- Keep the original language, notation and any code or numbers verbatim.\n"
        f"- Aim for about {target} tokens or fewer.\n"
        "- Output ONLY the compacted reasoning. No preamble, no commentary, "
        "no surrounding quotes or code fences.\n\n"
        "Reasoning to compact:\n"
        f"{text}"
    )


def _strip_wrapping(out):
    out = out.strip()
    # Some models wrap the answer in a fence or quotes despite the instruction.
    if out.startswith("```"):
        lines = out.splitlines()
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        out = "\n".join(lines).strip()
    if len(out) >= 2 and out[0] in "\"'" and out[-1] == out[0]:
        out = out[1:-1].strip()
    return out


def compact(text):
    """Run the on-device compaction pass. Returns the compacted text, or None
    if it failed or didn't actually shrink the input."""
    max_tokens = min(1536, max(128, estimate_tokens(text)))
    try:
        result = call("inference/complete", {
            "prompt": build_prompt(text),
            "tier": "medium",
            "maxTokens": max_tokens,
            "temperature": 0.2,
            "taskKind": "generation",
        }, timeout=180)
    except Exception as exc:
        _log(f"reasoning-compactor: inference failed: {exc}")
        return None
    out = _strip_wrapping((result or {}).get("text") or "")
    if not out:
        _log("reasoning-compactor: empty compaction")
        return None
    # If the model couldn't shrink it, don't pretend we saved anything.
    if len(out) >= len(text):
        _log("reasoning-compactor: already concise — no compaction applied")
        return None
    return out


def _pbcopy(text):
    """Set the system clipboard via the pbcopy subprocess (no host capability
    needed — same self-spawn pattern Burnout Copilot uses for Shortcuts)."""
    proc = subprocess.run(["/usr/bin/pbcopy"], input=text.encode("utf-8"),
                          timeout=10)
    return proc.returncode == 0


def _record_saving(before, after):
    global _session_saved, _session_runs
    saved = max(0, estimate_tokens(before) - estimate_tokens(after))
    with _state_lock:
        _session_saved += saved
        _session_runs += 1
        total = _session_saved
    return saved, total


# --- action: compact the current selection (hotkey ⌃⌥K) ----------------------

def handle_hotkey():
    if not _busy.acquire(blocking=False):
        _log("reasoning-compactor: busy, ignoring hotkey")
        return
    try:
        try:
            sel = call("ax/readSelection", {}, timeout=20) or {}
        except Exception as exc:
            _log(f"reasoning-compactor: readSelection failed: {exc}")
            return
        text = (sel.get("text") or "").strip()
        if len(text) < MIN_CHARS:
            call("ui/toast", {
                "title": "Reasoning Compactor",
                "body": "Select a reasoning trace (a few sentences or more), "
                        "then press ⌃⌥K.",
            })
            return

        before_tok = estimate_tokens(text)
        compacted = compact(text)
        if not compacted:
            call("ui/toast", {
                "title": "Reasoning Compactor",
                "body": f"That selection (~{before_tok} tokens) is already "
                        "about as tight as it gets.",
            })
            return

        if not _pbcopy(compacted):
            _log("reasoning-compactor: pbcopy failed")
            return

        saved, total = _record_saving(text, compacted)
        after_tok = estimate_tokens(compacted)
        pct = round(100 * saved / before_tok) if before_tok else 0
        call("ui/toast", {
            "title": "Reasoning compacted → clipboard",
            "body": (f"~{before_tok} → ~{after_tok} tokens "
                     f"(−{pct}%, {saved} saved). Press ⌘V to paste. "
                     f"Saved ~{total} this session."),
        })
        _log(f"reasoning-compactor: {before_tok}->{after_tok} tokens "
             f"(-{pct}%), session total {total}")
    finally:
        _busy.release()


# --- background: nudge when a bloated trace is detected -----------------------

def schedule_nudge(text):
    """Debounce: only look at a field once typing has settled."""
    global _nudge_timer
    if not looks_like_reasoning(text, NUDGE_MIN_CHARS):
        return
    with _nudge_timer_lock:
        if _nudge_timer is not None:
            _nudge_timer.cancel()
        _nudge_timer = threading.Timer(NUDGE_DEBOUNCE, consider_nudge, args=(text,))
        _nudge_timer.daemon = True
        _nudge_timer.start()


def consider_nudge(text):
    if _stop.is_set() or _busy.locked():
        return
    digest = hashlib.sha1(text.encode("utf-8")).hexdigest()
    now = time.time()
    with _state_lock:
        last = _recent_nudges.get(digest, 0)
        # Prune stale entries so the dict can't grow unbounded.
        for k in [k for k, t in _recent_nudges.items() if now - t > NUDGE_COOLDOWN]:
            _recent_nudges.pop(k, None)
        if now - last < NUDGE_COOLDOWN:
            return
        _recent_nudges[digest] = now

    before_tok = estimate_tokens(text)
    est_saved = round(before_tok * (1 - TARGET_KEEP_RATIO))
    if est_saved < NUDGE_MIN_SAVED_TOKENS:
        return
    _log(f"reasoning-compactor: bloated trace in focus (~{before_tok} tokens, "
         f"~{est_saved} saveable)")
    try:
        call("ui/toast", {
            "title": "Reasoning Compactor",
            "body": (f"This looks like a long reasoning trace (~{before_tok} "
                     f"tokens). Select it and press ⌃⌥K to compact "
                     f"— about {est_saved} tokens to save."),
        }, timeout=20)
    except Exception as exc:
        _log(f"reasoning-compactor: nudge toast failed: {exc}")


# --- startup -----------------------------------------------------------------

def startup():
    """Register the global hotkey once events are flowing."""
    try:
        call("hotkey/register", {
            "id": HOTKEY_ID,
            "keyCode": HOTKEY_KEYCODE,
            "modifiers": HOTKEY_MODIFIERS,
        }, timeout=20)
        _log("reasoning-compactor: registered hotkey ⌃⌥K")
    except Exception as exc:
        _log(f"reasoning-compactor: hotkey register failed: {exc}")


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
                threading.Thread(target=startup, daemon=True).start()
        elif method == "shutdown":
            _stop.set()
            with _state_lock:
                total, runs = _session_saved, _session_runs
            _log(f"reasoning-compactor: shutting down — compacted {runs} "
                 f"trace(s), ~{total} tokens saved this session")
            _send({"jsonrpc": "2.0", "id": msg["id"], "result": None})
        elif method == "exit":
            _stop.set()
            break
        elif method == "event/hotkey.fired":
            payload = (msg.get("params") or {}).get("payload") or {}
            if payload.get("id") == HOTKEY_ID:
                # Off the stdin thread — handle_hotkey blocks on host calls.
                threading.Thread(target=handle_hotkey, daemon=True).start()
        elif method == "event/text.pause":
            payload = (msg.get("params") or {}).get("payload") or {}
            schedule_nudge(payload.get("text") or "")
        elif method is None and "id" in msg:
            _resolve(msg)

    _stop.set()


if __name__ == "__main__":
    main()
