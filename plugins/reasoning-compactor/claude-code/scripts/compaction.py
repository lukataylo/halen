#!/usr/bin/env python3
"""Pure compaction logic for the Halen local-compaction Claude Code plugin.

Everything in this module is deterministic and side-effect free — no network,
no host, no model. The model call lives in `halen_bridge.py`; the hook
entrypoints (`precompact.py`, `session_start.py`) wire the two together. Keeping
the logic here means it is exercised by `test_compaction.py` under plain
`python3 test_compaction.py` with no Halen running.

The strategy mirrors Halen's Reasoning Compactor (and the 2025 CoT-compression
literature — TokenSkip, step-entropy, LLMLingua): default to *extractive*
compaction (the local model picks which transcript turns/steps to keep; the
output is rebuilt verbatim from the originals) so the summary can never invent
content that was not in your conversation. `abstractive` is available for a
tighter rewrite when you opt in.
"""
from __future__ import annotations

import json
import re

# --- defaults (mirrored in config.json) --------------------------------------

DEFAULTS = {
    "frequency": "auto",          # "auto" (manual + auto compaction) | "manual"
    "min_tokens": 6000,           # skip compaction below this transcript size
    "type": "extractive",         # "extractive" | "abstractive"
    "target_keep_ratio": 0.4,     # fraction of tokens to aim to keep
    "target_tokens": 0,           # absolute budget; > 0 overrides the ratio
    "preserve": ["code", "decisions", "final_answers"],
    "inject_on_resume": True,
    "model_tier": "medium",
    "bridge_port": 50765,
    "max_prompt_chars": 160000,   # keep the request frame under the bridge's 256 KB cap (with JSON-escaping headroom)
}

_VALID_FREQUENCY = {"auto", "manual"}
_VALID_TYPE = {"extractive", "abstractive"}
_VALID_TIER = {"classifier", "small", "medium", "large"}
_VALID_PRESERVE = {"code", "decisions", "final_answers"}


def estimate_tokens(text: str) -> int:
    """~4 chars/token — the same coarse heuristic Reasoning Compactor uses for
    its savings readout. Good enough for thresholding and the toast; we never
    bill against it."""
    if not text:
        return 0
    return max(1, round(len(text) / 4))


def _coerce_float(value, fallback: float, lo: float, hi: float) -> float:
    try:
        out = float(value)
    except (TypeError, ValueError, OverflowError):
        return fallback
    if out != out or out in (float("inf"), float("-inf")):  # NaN / inf
        return fallback
    return min(hi, max(lo, out))


def _coerce_int(value, fallback: int, lo: int, hi: int) -> int:
    try:
        out = int(value)
    except (TypeError, ValueError, OverflowError):
        return fallback
    return min(hi, max(lo, out))


def load_config(raw) -> dict:
    """Coerce an arbitrary parsed-JSON object (or anything) into a valid config.

    Robust against the file being missing, malformed, or hand-edited into junk:
    every key independently falls back to its default, and out-of-range numbers
    are clamped. Never raises."""
    cfg = dict(DEFAULTS)
    if not isinstance(raw, dict):
        return cfg

    freq = raw.get("frequency")
    if isinstance(freq, str) and freq.lower() in _VALID_FREQUENCY:
        cfg["frequency"] = freq.lower()

    ctype = raw.get("type")
    if isinstance(ctype, str) and ctype.lower() in _VALID_TYPE:
        cfg["type"] = ctype.lower()

    tier = raw.get("model_tier")
    if isinstance(tier, str) and tier.lower() in _VALID_TIER:
        cfg["model_tier"] = tier.lower()

    cfg["min_tokens"] = _coerce_int(raw.get("min_tokens"), DEFAULTS["min_tokens"], 0, 10_000_000)
    cfg["target_tokens"] = _coerce_int(raw.get("target_tokens"), DEFAULTS["target_tokens"], 0, 10_000_000)
    cfg["target_keep_ratio"] = _coerce_float(raw.get("target_keep_ratio"), DEFAULTS["target_keep_ratio"], 0.1, 0.95)
    cfg["bridge_port"] = _coerce_int(raw.get("bridge_port"), DEFAULTS["bridge_port"], 1, 65535)
    cfg["max_prompt_chars"] = _coerce_int(raw.get("max_prompt_chars"), DEFAULTS["max_prompt_chars"], 2000, 250000)

    if isinstance(raw.get("inject_on_resume"), bool):
        cfg["inject_on_resume"] = raw["inject_on_resume"]

    preserve = raw.get("preserve")
    if isinstance(preserve, list):
        kept = [p for p in preserve if isinstance(p, str) and p in _VALID_PRESERVE]
        cfg["preserve"] = kept  # may be empty if the user cleared it deliberately

    return cfg


def load_config_file(path) -> dict:
    """Read + parse config.json at `path`, returning a validated config. Any
    failure (missing file, bad JSON) yields the all-defaults config."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = json.load(fh)
    except (OSError, ValueError):
        return load_config(None)
    return load_config(raw)


def should_run(config: dict, trigger: str, transcript_tokens: int) -> bool:
    """Frequency gate. `manual` only engages when the user typed /compact;
    `auto` engages on both manual and automatic compaction. Either way we skip
    transcripts below `min_tokens` — there's nothing worth compacting."""
    if transcript_tokens < config["min_tokens"]:
        return False
    if config["frequency"] == "manual" and trigger != "manual":
        return False
    return True


# --- transcript parsing ------------------------------------------------------

def _text_from_content(content) -> str:
    """Flatten one message's `content` (string or list of blocks) into plain
    text. Keeps `text` and `thinking` blocks (the reasoning we most want to
    compact), notes tool calls compactly, and ignores binary/image blocks."""
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return ""
    parts: list[str] = []
    for block in content:
        if not isinstance(block, dict):
            continue
        btype = block.get("type")
        if btype == "text" and isinstance(block.get("text"), str):
            parts.append(block["text"].strip())
        elif btype == "thinking" and isinstance(block.get("thinking"), str):
            parts.append(block["thinking"].strip())
        elif btype == "tool_use":
            name = block.get("name", "tool")
            parts.append(f"[called {name}]")
        elif btype == "tool_result":
            parts.append("[tool result]")
    return "\n".join(p for p in parts if p)


def parse_transcript(jsonl_text: str) -> str:
    """Turn a Claude Code transcript (JSONL) into a single role-labelled string
    suitable for compaction. Skips system/summary bookkeeping lines and empty
    turns. Robust to malformed lines — a bad line is skipped, not fatal."""
    turns: list[str] = []
    for line in jsonl_text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if not isinstance(rec, dict):
            continue
        rtype = rec.get("type")
        if rtype not in ("user", "assistant"):
            continue
        message = rec.get("message")
        if not isinstance(message, dict):
            continue
        role = message.get("role", rtype)
        text = _text_from_content(message.get("content"))
        if not text:
            continue
        label = "User" if role == "user" else "Assistant"
        turns.append(f"{label}: {text}")
    return "\n\n".join(turns)


# --- prompt construction -----------------------------------------------------

def _preserve_clause(config: dict) -> str:
    wants = set(config.get("preserve") or [])
    bits = []
    if "code" in wants:
        bits.append("code blocks, file paths and exact identifiers verbatim")
    if "decisions" in wants:
        bits.append("every decision, requirement and constraint that was agreed")
    if "final_answers" in wants:
        bits.append("the latest state / conclusions and any open TODOs")
    if not bits:
        return ""
    return "Always keep: " + "; ".join(bits) + "."


def split_turns(transcript: str) -> list[str]:
    """Split a role-labelled transcript back into its turns (the units the
    extractive selector keeps or drops). Mirrors the `\\n\\n` join in
    `parse_transcript`."""
    return [t.strip() for t in transcript.split("\n\n") if t.strip()]


def clip_transcript(transcript: str, max_chars: int) -> str:
    """Keep whole trailing turns so the prompt frame stays under the bridge's
    256 KB cap. The tail of the conversation is the part most worth compacting
    accurately, so we drop from the front, on turn boundaries, and prepend a
    marker noting earlier turns were elided."""
    if len(transcript) <= max_chars:
        return transcript
    turns = split_turns(transcript)
    kept: list[str] = []
    total = 0
    marker = "[... earlier turns omitted ...]"
    for turn in reversed(turns):
        add = len(turn) + 2
        if total + add > max_chars - len(marker) - 2 and kept:
            break
        kept.append(turn)
        total += add
    kept.reverse()
    return marker + "\n\n" + "\n\n".join(kept)


def target_token_budget(config: dict, original_tokens: int) -> int:
    if config["target_tokens"] > 0:
        return config["target_tokens"]
    return max(1, round(original_tokens * config["target_keep_ratio"]))


def build_prompt(transcript: str, config: dict) -> tuple[str, str]:
    """Return (prompt, mode). `mode` is the resolved compaction type so the
    caller knows whether to expect an extractive keep-list or finished prose."""
    mode = config["type"]
    preserve = _preserve_clause(config)
    original_tokens = estimate_tokens(transcript)
    budget = target_token_budget(config, original_tokens)

    if mode == "extractive":
        turns = split_turns(transcript)
        numbered = "\n\n".join(f"[{i}] {t}" for i, t in enumerate(turns))
        prompt = (
            "You are compacting a coding-assistant conversation so it fits in a "
            "smaller context window. The conversation is split into numbered "
            "turns below. Choose the SMALLEST set of turns that preserves "
            "everything needed to continue the work — the task, decisions, "
            "current state and any code/paths. "
            f"{preserve} "
            f"Aim to keep about {budget} tokens of the original "
            f"{original_tokens}. "
            "Reply with ONLY the turn numbers to KEEP, in order, comma-"
            "separated, like: 0, 3, 4, 9. Do not add any other text.\n\n"
            f"{numbered}\n\nKEEP:"
        )
        return prompt, "extractive"

    # abstractive
    prompt = (
        "You are compacting a coding-assistant conversation so it fits in a "
        "smaller context window. Rewrite it as a tight briefing that lets the "
        "assistant resume with no loss of important information: the task, the "
        "decisions made, the current state of the code, and any open TODOs. "
        f"{preserve} "
        f"Target about {budget} tokens. Use terse bullet points; drop "
        "pleasantries and dead ends. Output only the briefing.\n\n"
        f"Conversation:\n{transcript}\n\nBriefing:"
    )
    return prompt, "abstractive"


# --- extractive reconstruction ----------------------------------------------

_NUM_RE = re.compile(r"\d+")


def parse_keep_indices(reply: str, num_turns: int) -> list[int] | None:
    """Parse the model's extractive reply into a sorted, de-duplicated list of
    in-range turn indices. Returns None when nothing usable can be parsed (the
    caller then falls back to an abstractive pass), so a chatty or empty reply
    never silently produces an empty compaction.

    Only standalone integer tokens count — a number glued inside a word
    (`step12`, `v2`) is ignored, mirroring Reasoning Compactor's parser, so the
    model echoing turn text can't be mistaken for selections."""
    if not reply:
        return None
    # Standalone integers: bounded by start/non-digit on each side.
    candidates = []
    for m in re.finditer(r"(?<![\w])\d+(?![\w])", reply):
        candidates.append(int(m.group()))
    in_range = sorted({n for n in candidates if 0 <= n < num_turns})
    if not in_range:
        return None
    return in_range


def reconstruct_extractive(transcript: str, reply: str) -> str | None:
    """Rebuild the compacted transcript from the original turns the model chose
    to keep. The final (most recent) turn is force-kept even if the model omits
    it — the tail of the conversation is the part you most need to resume.
    Returns None if the reply can't be parsed (fall back to abstractive)."""
    turns = split_turns(transcript)
    if not turns:
        return None
    keep = parse_keep_indices(reply, len(turns))
    if keep is None:
        return None
    keep_set = set(keep)
    keep_set.add(len(turns) - 1)  # force-keep the latest turn
    return "\n\n".join(turns[i] for i in sorted(keep_set))


# --- reporting ---------------------------------------------------------------

def compaction_stats(original: str, compacted: str) -> dict:
    o = estimate_tokens(original)
    c = estimate_tokens(compacted)
    ratio = (o / c) if c else 0.0
    pct = round((1 - c / o) * 100) if o else 0
    return {"original_tokens": o, "compacted_tokens": c, "ratio": ratio, "pct_saved": pct}


def _human_tokens(n: int) -> str:
    if n >= 1000:
        return f"{n / 1000:.1f}k"
    return str(n)


def summary_message(stats: dict, mode: str) -> str:
    o = _human_tokens(stats["original_tokens"])
    c = _human_tokens(stats["compacted_tokens"])
    return (
        f"\U0001F512 Halen compacted this context on-device ({mode}): "
        f"~{o} → {c} tokens (−{stats['pct_saved']}%). "
        "Local summary saved — it will be restored if you resume this session. "
        "Nothing was sent to the cloud for this summary."
    )
