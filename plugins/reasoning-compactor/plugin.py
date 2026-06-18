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
literature (Alibaba's step-entropy work; TokenSkip, EMNLP 2025; Microsoft's
LLMLingua): keep the high-information reasoning steps, prune the low-information
connective filler, and preserve the conclusion, equations and code verbatim.
Design choices borrowed from those projects — ratio *and* absolute-budget
compression modes, protected (never-compressed) code segments, dollar-savings
metrics, and chunking of long inputs — are documented in README.md.

Every privileged operation (reading the selection, running inference, posting
the notification) goes through the host over JSON-RPC — this plugin holds no
macOS entitlements of its own and links no system frameworks. Setting the
clipboard uses /usr/bin/pbcopy, a subprocess the plugin spawns itself (same
pattern Burnout Copilot uses for its Shortcuts trigger).

Protocol: JSON-RPC 2.0, newline-delimited. stdin = host -> plugin,
stdout = plugin -> host, stderr = log (forwarded into Halen's unified log).
"""
import os
import re
import sys
import json
import time
import shlex
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


# --- configuration -----------------------------------------------------------

# Defaults; overridable by a sibling config.json and a few HALEN_RC_* env vars.
# `target_keep_ratio` and `target_tokens` mirror LLMLingua's two compression
# modes (`rate` vs `target_token`): if `target_tokens > 0` it wins and sets an
# absolute budget, otherwise the ratio is used.
DEFAULTS = {
    # "extractive" keeps a verbatim subset of the original steps (the mechanism
    # TokenSkip / step-entropy / LLMLingua actually use — faithful by
    # construction); "abstractive" lets the model rewrite the trace shorter.
    "mode": "extractive",
    "target_keep_ratio": 0.45,      # keep ~45% of tokens (≈ TokenSkip's cut)
    "target_tokens": 0,             # >0 ⇒ absolute output budget, overrides ratio
    "usd_per_million_tokens": 3.0,  # for the $-saved estimate in toasts
    "min_chars": 480,               # min selection before ⌃⌥K does anything
    "nudge_min_chars": 900,
    "nudge_min_saved_tokens": 80,
    "nudge_cooldown_seconds": 8 * 60,
    "max_single_pass_tokens": 1200,  # chunk prose above this so output ≠ truncated
    "clipboard_cmd": ["/usr/bin/pbcopy"],
    "hotkey_keycode": 40,            # kVK_ANSI_K
    "hotkey_modifiers": 0x1000 | 0x800,  # ⌃⌥ (controlKey | optionKey)
}

HOTKEY_ID = "reasoning-compactor.compact"


def load_config():
    cfg = dict(DEFAULTS)
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json")
    try:
        with open(path, encoding="utf-8") as fh:
            user = json.load(fh)
        for key, val in (user or {}).items():
            if key in cfg:
                cfg[key] = val
        _log(f"reasoning-compactor: loaded config.json ({len(user)} key(s))")
    except FileNotFoundError:
        pass
    except Exception as exc:
        _log(f"reasoning-compactor: bad config.json ignored ({exc})")

    # Env overrides — mostly for testing / unusual setups.
    clip = os.environ.get("HALEN_RC_CLIPBOARD_CMD")
    if clip:
        cfg["clipboard_cmd"] = shlex.split(clip)
    ratio = os.environ.get("HALEN_RC_TARGET_RATIO")
    if ratio:
        try:
            cfg["target_keep_ratio"] = float(ratio)
        except ValueError:
            pass
    tt = os.environ.get("HALEN_RC_TARGET_TOKENS")
    if tt:
        try:
            cfg["target_tokens"] = int(tt)
        except ValueError:
            pass

    mode = os.environ.get("HALEN_RC_MODE", cfg["mode"])
    cfg["mode"] = mode if mode in ("extractive", "abstractive") else "extractive"

    # Coerce every numeric key defensively. A malformed value in config.json
    # (e.g. "high" where a float is expected) must fall back to its default,
    # never raise at import — an uncaught exception here kills the plugin
    # process before the JSON-RPC handshake, so the host just sees a startup
    # timeout. This is what config.json's "_comment" and the README promise.
    def _num(key, cast, lo=None, hi=None):
        try:
            v = cast(cfg[key])
        except (TypeError, ValueError):
            v = DEFAULTS[key]
        if lo is not None:
            v = max(lo, v)
        if hi is not None:
            v = min(hi, v)
        cfg[key] = v

    _num("target_keep_ratio", float, 0.1, 0.95)
    _num("target_tokens", int, 0)
    _num("usd_per_million_tokens", float, 0.0)
    _num("min_chars", int, 0)
    _num("nudge_min_chars", int, 0)
    _num("nudge_min_saved_tokens", int, 0)
    _num("nudge_cooldown_seconds", int, 0)
    _num("max_single_pass_tokens", int, 1)
    _num("hotkey_keycode", int, 0)
    _num("hotkey_modifiers", int, 0)

    if not isinstance(cfg["clipboard_cmd"], list) or not cfg["clipboard_cmd"]:
        cfg["clipboard_cmd"] = list(DEFAULTS["clipboard_cmd"])
    return cfg


CFG = load_config()

# --- shared state ------------------------------------------------------------

_state_lock = threading.Lock()
_busy = threading.Lock()           # one compaction interaction at a time
_nudge_timer = None
_nudge_timer_lock = threading.Lock()
_recent_nudges = {}                # text-hash -> epoch of last nudge
_session_saved = 0                 # running total of tokens saved this session
_session_runs = 0


# --- token estimation & formatting -------------------------------------------

def estimate_tokens(text):
    """Rough token count. ~4 chars/token is the usual back-of-envelope for
    English prose and code; good enough to report savings and size requests."""
    return max(1, round(len(text) / 4))


def fmt_tokens(n):
    return f"{n / 1000:.1f}k" if n >= 1000 else str(int(n))


def usd_saved(tokens):
    return tokens / 1_000_000 * CFG["usd_per_million_tokens"]


def target_tokens_for(input_tokens):
    """Output budget for an input of this size — absolute if configured, else
    the keep-ratio. Never asks for more tokens than the input has."""
    if CFG["target_tokens"] > 0:
        return max(1, min(CFG["target_tokens"], input_tokens))
    return max(1, round(input_tokens * CFG["target_keep_ratio"]))


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


def looks_like_reasoning(text, min_chars=None):
    min_chars = CFG["min_chars"] if min_chars is None else min_chars
    return len(text) >= min_chars and reasoning_signal(text) >= 2


# --- compaction --------------------------------------------------------------

_FENCE_RE = re.compile(r"^\s*```")


def segment(text):
    """Split into ordered (kind, content) segments where kind is "code" (a
    fenced block — never compressed, mirroring LLMLingua's compress=False
    sections, since code carries the reasoning) or "prose" (compressible)."""
    segs = []
    cur = []
    in_code = False
    for line in text.split("\n"):
        is_fence = bool(_FENCE_RE.match(line))
        if is_fence and not in_code:
            if cur:
                segs.append(("prose", "\n".join(cur)))
                cur = []
            in_code = True
            cur.append(line)
        elif is_fence and in_code:
            cur.append(line)
            segs.append(("code", "\n".join(cur)))
            cur = []
            in_code = False
        else:
            cur.append(line)
    if cur:
        # An unclosed fence is treated as code (pass-through) — safer than
        # feeding a half-open block to the model.
        segs.append(("code" if in_code else "prose", "\n".join(cur)))
    return segs


def chunk_prose(text, budget):
    """Group paragraphs into chunks no larger than `budget` tokens so a single
    inference call's output can't be truncated by maxTokens."""
    parts = re.split(r"\n\s*\n", text)
    chunks, cur, cur_tok = [], [], 0
    for para in parts:
        t = estimate_tokens(para)
        if cur and cur_tok + t > budget:
            chunks.append("\n\n".join(cur))
            cur, cur_tok = [], 0
        cur.append(para)
        cur_tok += t
    if cur:
        chunks.append("\n\n".join(cur))
    return chunks


_SENT_SPLIT = re.compile(r"(?<=[.!?])\s+")
_ANSWER_RE = re.compile(
    r"(final answer|the answer is|answer\s*[:=]|in conclusion|conclusion\s*:|"
    r"result is|hence the|therefore the)", re.I)
_PARSE_FAILED = object()   # extractive sentinel: model gave no usable indices


def split_steps(prose):
    """Split a prose passage into atomic reasoning steps (newline- then
    sentence-delimited). Extractive compaction selects a subset of these."""
    steps = []
    for line in prose.split("\n"):
        line = line.strip()
        if not line:
            continue
        for sent in _SENT_SPLIT.split(line):
            sent = sent.strip()
            if sent:
                steps.append(sent)
    return steps


def _extractive_prompt(steps, keep_n):
    numbered = "\n".join(f"{i + 1}. {s}" for i, s in enumerate(steps))
    return (
        "Below is an LLM's chain-of-thought, split into numbered steps. Select "
        "the MINIMAL set of steps that preserves the logic and the final "
        f"answer. Keep about {keep_n} of the {len(steps)} steps — the "
        "load-bearing ones (facts, equations, intermediate results, decisions, "
        "the final answer). Drop filler: self-talk, restatements, hedging, "
        "dead-end second-guessing.\n"
        "Output ONLY the numbers of the steps to KEEP, comma-separated, in any "
        "order. No other text.\n\n"
        f"Steps:\n{numbered}"
    )


def _extractive_pass(prose, target):
    """Faithful compaction: ask the model which steps to KEEP, then rebuild the
    passage from those original steps verbatim — the mechanism TokenSkip /
    step-entropy / LLMLingua use. Returns the kept text, None if not worth
    compacting, or `_PARSE_FAILED` if the model's reply had no usable indices."""
    steps = split_steps(prose)
    if len(steps) <= 2:
        return None
    input_tok = estimate_tokens(prose)
    keep_ratio = min(1.0, target / input_tok) if input_tok else 1.0
    keep_n = max(1, round(len(steps) * keep_ratio))
    if keep_n >= len(steps):
        return None
    try:
        result = call("inference/complete", {
            "prompt": _extractive_prompt(steps, keep_n),
            "tier": "medium",
            "maxTokens": 128,
            "temperature": 0.0,
            "taskKind": "classification",
        }, timeout=120)
    except Exception as exc:
        _log(f"reasoning-compactor: extractive inference failed: {exc}")
        return _PARSE_FAILED
    raw = (result or {}).get("text") or ""
    model_idxs = sorted({int(n) - 1 for n in re.findall(r"\d+", raw)
                         if 1 <= int(n) <= len(steps)})
    if not model_idxs:
        return _PARSE_FAILED
    # Guarantee the conclusion survives: always keep the final step and any
    # step that states an answer, even if the model dropped it.
    forced = {len(steps) - 1}
    forced |= {i for i, s in enumerate(steps) if _ANSWER_RE.search(s)}
    idxs = sorted(set(model_idxs) | forced)
    if len(idxs) >= len(steps):
        return None
    kept = " ".join(steps[i] for i in idxs)
    return kept if len(kept) < len(prose) else None


def _abstractive_prompt(text, target):
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
        "- Preserve the final answer / conclusion exactly as written.\n"
        "- Keep equations, code, numbers, identifiers and notation verbatim — "
        "they carry the reasoning and must not be paraphrased.\n"
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


def _abstractive_pass(text, target):
    """One on-device rewrite call. Returns the compacted text, or None on
    failure / if it didn't actually shrink this passage."""
    # We compress, so the output is shorter than the input; 0.9× the input
    # (capped) is ample headroom and never truncates a genuine compaction.
    max_tokens = min(2048, max(256, round(estimate_tokens(text) * 0.9)))
    try:
        result = call("inference/complete", {
            "prompt": _abstractive_prompt(text, target),
            "tier": "medium",
            "maxTokens": max_tokens,
            "temperature": 0.2,
            "taskKind": "generation",
        }, timeout=180)
    except Exception as exc:
        _log(f"reasoning-compactor: inference failed: {exc}")
        return None
    out = _strip_wrapping((result or {}).get("text") or "")
    if not out or len(out) >= len(text):
        return None
    return out


def _compact_passage(text, target):
    """Compact one prose passage using the configured mode. Extractive is
    faithful-by-construction (a verbatim subset of the original); on a parse
    failure it falls back to an abstractive rewrite so a stubborn model still
    gets compaction."""
    if CFG["mode"] == "extractive":
        res = _extractive_pass(text, target)
        if res is _PARSE_FAILED:
            _log("reasoning-compactor: extractive parse failed → abstractive")
            return _abstractive_pass(text, target)
        return res
    return _abstractive_pass(text, target)


def compact(text):
    """Compact a reasoning trace. Single pass for ordinary inputs; for inputs
    with fenced code or above the single-pass budget, code blocks are preserved
    verbatim and prose is compacted chunk-by-chunk, then reassembled in order.
    Each prose passage goes through `_compact_passage` (extractive by default).
    Returns the compacted text, or None if nothing got smaller."""
    total_in = estimate_tokens(text)
    segs = segment(text)
    has_code = any(kind == "code" for kind, _ in segs)

    if not has_code and total_in <= CFG["max_single_pass_tokens"]:
        return _compact_passage(text, target_tokens_for(total_in))

    out_parts = []
    changed = False
    budget = CFG["max_single_pass_tokens"]
    for kind, content in segs:
        if kind == "code" or not content.strip():
            out_parts.append(content)
            continue
        passages = ([content] if estimate_tokens(content) <= budget
                    else chunk_prose(content, budget))
        for passage in passages:
            res = _compact_passage(passage, target_tokens_for(estimate_tokens(passage)))
            if res:
                out_parts.append(res)
                changed = True
            else:
                out_parts.append(passage)

    if not changed:
        return None
    combined = "\n\n".join(p for p in out_parts if p.strip())
    return combined if len(combined) < len(text) else None


def _clipboard_set(text):
    """Set the system clipboard via the configured command (pbcopy by default)
    — a subprocess the plugin spawns itself, no host capability involved."""
    try:
        proc = subprocess.run(CFG["clipboard_cmd"], input=text.encode("utf-8"),
                              timeout=10)
        return proc.returncode == 0
    except Exception as exc:
        _log(f"reasoning-compactor: clipboard set failed ({exc})")
        return False


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
        if len(text) < CFG["min_chars"]:
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
                "body": f"That selection (~{fmt_tokens(before_tok)} tokens) is "
                        "already about as tight as it gets.",
            })
            return

        if not _clipboard_set(compacted):
            call("ui/toast", {
                "title": "Reasoning Compactor",
                "body": "Compacted, but couldn't reach the clipboard. "
                        "Check the clipboard command in config.json.",
            })
            return

        saved, total = _record_saving(text, compacted)
        after_tok = estimate_tokens(compacted)
        pct = round(100 * saved / before_tok) if before_tok else 0
        mult = before_tok / after_tok if after_tok else 1.0
        body = (f"~{fmt_tokens(before_tok)} → ~{fmt_tokens(after_tok)} tokens · "
                f"{mult:.1f}× smaller (−{pct}%). Press ⌘V to paste.")
        dollars = usd_saved(total)
        session = f" Session: ~{fmt_tokens(total)} tokens saved"
        if dollars >= 0.005:
            session += f" (~${dollars:.2f})"
        call("ui/toast", {"title": "Reasoning compacted → clipboard",
                          "body": body + session + "."})
        _log(f"reasoning-compactor: {before_tok}->{after_tok} tokens "
             f"(-{pct}%, {mult:.1f}x), session total {total}")
    finally:
        _busy.release()


# --- background: nudge when a bloated trace is detected -----------------------

def schedule_nudge(text):
    """Debounce: only look at a field once typing has settled."""
    global _nudge_timer
    if not looks_like_reasoning(text, CFG["nudge_min_chars"]):
        return
    with _nudge_timer_lock:
        if _nudge_timer is not None:
            _nudge_timer.cancel()
        _nudge_timer = threading.Timer(2.0, consider_nudge, args=(text,))
        _nudge_timer.daemon = True
        _nudge_timer.start()


def consider_nudge(text):
    if _stop.is_set() or _busy.locked():
        return
    digest = hashlib.sha1(text.encode("utf-8")).hexdigest()
    now = time.time()
    cooldown = CFG["nudge_cooldown_seconds"]
    with _state_lock:
        last = _recent_nudges.get(digest, 0)
        for stale in [k for k, t in _recent_nudges.items() if now - t > cooldown]:
            _recent_nudges.pop(stale, None)
        if now - last < cooldown:
            return
        _recent_nudges[digest] = now

    before_tok = estimate_tokens(text)
    est_saved = round(before_tok * (1 - CFG["target_keep_ratio"]))
    if est_saved < CFG["nudge_min_saved_tokens"]:
        return
    _log(f"reasoning-compactor: bloated trace in focus (~{before_tok} tokens, "
         f"~{est_saved} saveable)")
    try:
        call("ui/toast", {
            "title": "Reasoning Compactor",
            "body": (f"This looks like a long reasoning trace "
                     f"(~{fmt_tokens(before_tok)} tokens). Select it and press "
                     f"⌃⌥K to compact — about {est_saved} tokens to save."),
        }, timeout=20)
    except Exception as exc:
        _log(f"reasoning-compactor: nudge toast failed: {exc}")


# --- startup -----------------------------------------------------------------

def startup():
    """Register the global hotkey once events are flowing."""
    try:
        call("hotkey/register", {
            "id": HOTKEY_ID,
            "keyCode": CFG["hotkey_keycode"],
            "modifiers": CFG["hotkey_modifiers"],
        }, timeout=20)
        _log("reasoning-compactor: registered compaction hotkey")
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
