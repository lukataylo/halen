#!/usr/bin/env python3
"""halen-compact — standalone local chain-of-thought compactor.

Compacts verbose LLM reasoning traces using a local Ollama model, without
needing the Halen app running. Designed for Claude Code users who want to
save context tokens by compressing long reasoning outputs locally.

Usage:
  # Compact text from stdin → stdout
  pbpaste | python3 scripts/halen-compact.py | pbcopy

  # Compact a file
  python3 scripts/halen-compact.py reasoning.txt

  # --detect: pull the reasoning chain out of a noisy blob (e.g. a tmux pane's
  # scrollback) and compact only that, leaving prompts/command output behind.
  tmux capture-pane -p -S -3000 | python3 scripts/halen-compact.py --detect --stats

  # Bind it to a tmux key (per-pane, on-demand) — see scripts/halen-tmux-compact.sh
  # and the README. Note: Claude Code's own thinking is redacted in its transcript
  # and lives on the alt-screen, so this captures reasoning a tool *prints* to the
  # pane (deepseek-r1 / qwen <think>…</think>, `ollama run`, …), not CC's thinking.

  # From inside Claude Code (paste compacted result back yourself):
  ! pbpaste | python3 /path/to/halen-compact.py | pbcopy && echo "Compacted — ⌘V to paste"

  # As a Claude Code hook (add to CLAUDE.md):
  # hooks:
  #   Stop:
  #     - matcher: ""
  #       hooks:
  #         - type: command
  #           command: "python3 /path/to/scripts/halen-compact.py --claude-hook"

Requirements:
  Ollama running locally (https://ollama.com):
    ollama pull gemma4:e2b   # fast, good for extractive (small tier)
    ollama pull gemma4:e4b   # better quality, slower (medium tier)

  Or any other Ollama-compatible model; set HALEN_COMPACT_MODEL env var.

Environment variables:
  HALEN_COMPACT_MODEL   Ollama model name (default: gemma4:e2b)
  HALEN_COMPACT_URL     Ollama API base URL (default: http://localhost:11434)
  HALEN_COMPACT_RATIO   Target keep ratio 0.1–0.95 (default: 0.45)
  HALEN_COMPACT_MODE    extractive | abstractive (default: extractive)
"""
import os
import re
import sys
import json
import argparse
import urllib.request
import urllib.error


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

MODEL   = os.environ.get("HALEN_COMPACT_MODEL", "gemma4:e2b")
API_URL = os.environ.get("HALEN_COMPACT_URL",   "http://localhost:11434").rstrip("/")
RATIO   = float(os.environ.get("HALEN_COMPACT_RATIO", "0.45"))
MODE    = os.environ.get("HALEN_COMPACT_MODE",  "extractive")
if MODE not in ("extractive", "abstractive"):
    MODE = "extractive"


# ---------------------------------------------------------------------------
# Token estimation (mirrors plugin.py: ~0.75 words per token)
# ---------------------------------------------------------------------------

def estimate_tokens(text: str) -> int:
    return max(1, round(len(text.split()) / 0.75))


def fmt_tokens(n: int) -> str:
    return f"{n/1000:.1f}k" if n >= 1000 else str(n)


# ---------------------------------------------------------------------------
# Step splitting (same heuristic as plugin.py)
# ---------------------------------------------------------------------------

_SENT_SPLIT = re.compile(r"(?<=[.!?])\s+")
_ANSWER_RE  = re.compile(
    r"\b(therefore|thus|so|hence|answer(?:ing)?|result(?:ing)?|conclude|"
    r"final(?:ly)?|output|equals?|is\s+(?:then\s+)?(?:\d|[A-Z]))",
    re.IGNORECASE,
)


def split_steps(prose: str) -> list[str]:
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


# ---------------------------------------------------------------------------
# Reasoning detection (for --detect, e.g. tmux scrollback)
# ---------------------------------------------------------------------------

# Substrings common in step-by-step "thinking" but rare in finished prose /
# shell output. Ported from plugins/reasoning-compactor/plugin.py.
_MARKERS = (
    "<think>", "</think>", "let me", "let's", "first,", "firstly", "step 1",
    "step 2", "step-by-step", "wait,", "hmm", "okay,", "ok,", "therefore",
    "thus,", "so we", "so the", "we need", "we have", "i need to", "i should",
    "reconsider", "on second thought", "but wait", "alternatively", "actually,",
    "to summarize", "in summary", "the answer is", "final answer",
    "chain of thought", "reasoning:",
)
_THINK_RE = re.compile(r"<think>(.*?)</think>", re.DOTALL | re.IGNORECASE)


def _reasoning_signal(text: str) -> int:
    low = text.lower()
    return sum(1 for m in _MARKERS if m in low)


def find_reasoning(blob: str) -> list[str]:
    """Pull the reasoning chain(s) out of a larger blob (tmux scrollback, a log).

    Explicit <think>…</think> spans win when present. A <think> that was opened
    but never closed (the close tag scrolled off, or the model was still
    streaming) is taken from the tag to end of input. Otherwise merge contiguous
    blank-line-delimited blocks that carry reasoning markers and return the
    most marker-rich run — pane scrollback is mostly prompts and command output,
    so we want the reasoning region, not the whole capture.
    ponytail: returns one run; if a pane holds several distinct traces, take
    runs[:N] instead — single-trace is the common case."""
    spans = [m.group(1).strip() for m in _THINK_RE.finditer(blob)]
    spans = [s for s in spans if s]
    if spans:
        return spans

    # Opened-but-unclosed <think>: salvage from the tag to EOF.
    low = blob.lower()
    open_idx = low.rfind("<think>")
    if open_idx != -1 and "</think>" not in low[open_idx:]:
        tail = blob[open_idx + len("<think>"):].strip()
        if tail:
            return [tail]

    blocks = [b.strip() for b in re.split(r"\n\s*\n", blob)]
    runs, cur = [], []
    for b in blocks:
        if b and _reasoning_signal(b) >= 1:
            cur.append(b)
        elif cur:
            runs.append("\n\n".join(cur))
            cur = []
    if cur:
        runs.append("\n\n".join(cur))
    runs = [r for r in runs if len(r) >= 300 and _reasoning_signal(r) >= 2]
    # Most reasoning markers first, longest as the tiebreak — a marker-dense run
    # is likelier the real chain than a merely long one.
    runs.sort(key=lambda r: (_reasoning_signal(r), len(r)), reverse=True)
    return runs[:1]


# ---------------------------------------------------------------------------
# Ollama inference
# ---------------------------------------------------------------------------

def _ollama_generate(prompt: str, max_tokens: int = 256, temperature: float = 0.0) -> str:
    payload = json.dumps({
        "model": MODEL,
        "prompt": prompt,
        "stream": False,
        "think": False,  # ponytail: gemma4/thinking models burn num_predict on CoT and return empty; we only want the answer
        "options": {
            "temperature": temperature,
            "num_predict": max_tokens,
        },
    }).encode()
    req = urllib.request.Request(
        f"{API_URL}/api/generate",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.load(resp)
            return (data.get("response") or "").strip()
    except urllib.error.URLError as exc:
        print(f"[halen-compact] Ollama unavailable ({exc}). Is Ollama running?",
              file=sys.stderr)
        print(f"  Start it: ollama serve", file=sys.stderr)
        print(f"  Pull a model: ollama pull {MODEL}", file=sys.stderr)
        sys.exit(1)


# ---------------------------------------------------------------------------
# Extractive compaction
# ---------------------------------------------------------------------------

def _extractive_prompt(steps: list[str], keep_n: int) -> str:
    numbered = "\n".join(f"{i + 1}. {s}" for i, s in enumerate(steps))
    return (
        "Below is an LLM's chain-of-thought, split into numbered steps. Select "
        "the MINIMAL set of steps that preserves the logic and the final answer. "
        f"Keep about {keep_n} of the {len(steps)} steps — the load-bearing ones "
        "(facts, equations, intermediate results, decisions, the final answer). "
        "Drop filler: self-talk, restatements, hedging, dead-end second-guessing.\n"
        "Output ONLY the numbers of the steps to KEEP, comma-separated. No other text.\n\n"
        f"Steps:\n{numbered}"
    )


def _select_kept_steps(raw: str, steps: list[str]):
    tokens = [t for t in re.split(r"[,\s]+", raw.strip()) if t]
    nums = [int(t) for t in tokens if t.isdigit()]
    non_numeric = [t for t in tokens if not t.isdigit()]
    if len(non_numeric) > len(nums):
        return None  # model ignored format → fall back
    idxs = {n - 1 for n in nums if 1 <= n <= len(steps)}
    if not idxs:
        return None
    forced = {len(steps) - 1}
    forced |= {i for i, s in enumerate(steps) if _ANSWER_RE.search(s)}
    return sorted(idxs | forced)


def _extractive_pass(text: str, target: int):
    steps = split_steps(text)
    if len(steps) <= 2:
        return None
    total = estimate_tokens(text)
    keep_ratio = min(1.0, target / total) if total else 1.0
    keep_n = max(1, round(len(steps) * keep_ratio))
    if keep_n >= len(steps):
        return None
    raw = _ollama_generate(_extractive_prompt(steps, keep_n), max_tokens=128)
    idxs = _select_kept_steps(raw, steps)
    if idxs is None:
        return None
    kept = " ".join(steps[i] for i in idxs)
    return kept if len(kept) < len(text) else None


# ---------------------------------------------------------------------------
# Abstractive compaction
# ---------------------------------------------------------------------------

def _abstractive_prompt(text: str, target: int) -> str:
    return (
        "You compress an LLM's chain-of-thought reasoning. Rewrite the reasoning "
        "below so it is much shorter while staying a faithful, verifiable trace "
        "of the SAME logic.\n\n"
        "Rules:\n"
        "- Keep every load-bearing step: facts, equations, decisions, intermediate results.\n"
        "- Drop low-information filler: self-talk, restatements, hedging, dead ends.\n"
        "- Preserve the final answer / conclusion exactly as written.\n"
        "- Keep equations, code, numbers, identifiers verbatim.\n"
        f"- Aim for about {target} tokens or fewer.\n"
        "- Output ONLY the compacted reasoning. No preamble, no commentary.\n\n"
        f"Reasoning:\n{text}"
    )


def _abstractive_pass(text: str, target: int):
    max_tokens = min(2048, max(256, round(estimate_tokens(text) * 0.9)))
    out = _ollama_generate(_abstractive_prompt(text, target),
                           max_tokens=max_tokens, temperature=0.2)
    # Strip wrapping fences/quotes some models add despite instruction
    out = out.strip()
    if out.startswith("```"):
        lines = out.splitlines()
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        out = "\n".join(lines).strip()
    if len(out) >= 2 and out[0] in "\"'" and out[-1] == out[0]:
        out = out[1:-1].strip()
    return out if out and len(out) < len(text) else None


# ---------------------------------------------------------------------------
# Combined compaction
# ---------------------------------------------------------------------------

def compact(text: str) -> str | None:
    total = estimate_tokens(text)
    target = max(1, round(total * RATIO))
    if MODE == "extractive":
        result = _extractive_pass(text, target)
        if result is None:
            result = _abstractive_pass(text, target)
    else:
        result = _abstractive_pass(text, target)
    return result


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def _selftest():
    # <think> tags win and are extracted verbatim.
    assert find_reasoning("noise\n<think>let me check x=1</think>\n$ ls") == \
        ["let me check x=1"], "think-tag extraction"
    # An opened-but-unclosed <think> is salvaged to end of input.
    assert find_reasoning("noise\n<think>let me check x=1 then continue") == \
        ["let me check x=1 then continue"], "unclosed think-tag salvage"
    # A closed think present alongside other text still wins (not the fallback).
    assert find_reasoning("<think>a</think> later <think>b") == ["a"], \
        "closed think preferred over unclosed"
    # A reasoning run is pulled out of surrounding shell noise.
    blob = (
        "$ run something\noutput line\n\n"
        "Let me work this out step-by-step. First, we have a=2 and b=2. "
        "We need to combine them. Therefore the sum a+b matters here. "
        "Hmm, wait, let me reconsider whether multiplication is intended. "
        "Actually, the problem asks for the product, so we have a*b. "
        "Thus the result is 4. The answer is 4, and that is the final answer.\n\n"
        "$ next command\nmore output\n"
    )
    found = find_reasoning(blob)
    assert found and "answer is 4" in found[0], f"run detection: {found}"
    assert "run something" not in found[0], "shell noise leaked into reasoning"
    # Pure command output trips nothing.
    assert find_reasoning("$ ls\nfile1\nfile2\n$ pwd\n/home") == [], "false positive"
    # Step parsing keeps the conclusion even if the model drops it.
    steps = ["a is 2", "filler chatter", "the answer is 4"]
    assert _select_kept_steps("1", steps) == [0, 2], "conclusion not forced in"
    # Non-numeric model reply → parse failure (None), caller falls back.
    assert _select_kept_steps("I think keep step one please", steps) is None, "bad-format guard"
    print("halen-compact selftest: OK")


def main():
    parser = argparse.ArgumentParser(
        description="Compact LLM reasoning traces locally via Ollama.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("file", nargs="?", help="Input file (default: stdin)")
    parser.add_argument("--claude-hook", action="store_true",
                        help="Run as a Claude Code Stop hook (no-op if context is short)")
    parser.add_argument("--detect", action="store_true",
                        help="Find the reasoning chain in a noisy blob (e.g. tmux "
                             "scrollback) and compact only that")
    parser.add_argument("--stats", action="store_true",
                        help="Print token stats to stderr")
    parser.add_argument("--selftest", action="store_true",
                        help="Run offline self-checks (no Ollama needed) and exit")
    args = parser.parse_args()

    if args.selftest:
        _selftest()
        return

    if args.file:
        with open(args.file, encoding="utf-8") as fh:
            text = fh.read()
    else:
        text = sys.stdin.read()

    text = text.strip()
    if not text:
        sys.exit(0)

    # --detect: extract reasoning from the blob, compact each block, print only
    # the compacted reasoning (the prompts/command-output around it are dropped).
    if args.detect:
        blocks = find_reasoning(text)
        if not blocks:
            print("[halen-compact] No reasoning chain found in input.",
                  file=sys.stderr)
            sys.exit(0)
        for blk in blocks:
            before = estimate_tokens(blk)
            res = compact(blk) or blk
            after = estimate_tokens(res)
            sys.stdout.write(res.rstrip() + "\n")
            if args.stats:
                saved = before - after
                pct = round(100 * saved / before) if before else 0
                print(f"[halen-compact] {fmt_tokens(before)} → {fmt_tokens(after)} "
                      f"tokens (-{pct}%) via {MODEL}", file=sys.stderr)
        sys.exit(0)

    before = estimate_tokens(text)

    # In Claude Code hook mode, skip short outputs — not worth compacting
    if args.claude_hook and before < 300:
        sys.stdout.write(text)
        sys.exit(0)

    result = compact(text)
    if result is None:
        # Nothing compressible — pass through unchanged
        sys.stdout.write(text)
        if args.stats:
            print(f"[halen-compact] Nothing to compact (~{fmt_tokens(before)} tokens)",
                  file=sys.stderr)
        sys.exit(0)

    after = estimate_tokens(result)
    saved = before - after
    pct = round(100 * saved / before) if before else 0

    sys.stdout.write(result)
    if not result.endswith("\n"):
        sys.stdout.write("\n")

    if args.stats or args.claude_hook:
        print(f"[halen-compact] {fmt_tokens(before)} → {fmt_tokens(after)} tokens "
              f"(-{pct}%, {before/after:.1f}× smaller) via {MODEL}",
              file=sys.stderr)


if __name__ == "__main__":
    main()
