#!/usr/bin/env python3
"""PreCompact hook — compact the transcript on-device through Halen.

Claude Code fires this immediately before it compacts the context (the user's
`/compact`, or automatically when the window fills). We read the transcript,
ask the *local* Halen model to compact it (extractive by default), and save the
result so `session_start.py` can restore it when the session resumes — your
conversation is never sent to the cloud for this summary.

This hook never blocks or alters Claude Code's own compaction: any failure
(Halen not running, model busy) logs to stderr and exits 0 cleanly. The worst
case is "no local summary this time", never a broken /compact.
"""
from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compaction as C  # noqa: E402
import halen_bridge as bridge  # noqa: E402


def _plugin_root() -> str:
    env = os.environ.get("CLAUDE_PLUGIN_ROOT")
    if env:
        return env
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _state_dir(root: str) -> str:
    path = os.path.join(root, "state")
    os.makedirs(path, exist_ok=True)
    return path


def _read_transcript(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return ""


def _save_summary(root: str, session_id: str, summary: str, meta: dict) -> None:
    state = _state_dir(root)
    safe = "".join(c for c in session_id if c.isalnum() or c in "-_") or "session"
    with open(os.path.join(state, f"{safe}.md"), "w", encoding="utf-8") as fh:
        fh.write(summary)
    with open(os.path.join(state, f"{safe}.json"), "w", encoding="utf-8") as fh:
        json.dump(meta, fh)


def _emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj))
    sys.stdout.flush()


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 0
    if not isinstance(payload, dict):
        return 0

    session_id = str(payload.get("session_id") or "session")
    trigger = str(payload.get("trigger") or "auto")
    transcript_path = payload.get("transcript_path")

    root = _plugin_root()
    cfg = C.load_config_file(os.path.join(root, "config.json"))

    raw = _read_transcript(transcript_path) if isinstance(transcript_path, str) else ""
    transcript = C.parse_transcript(raw)
    if not transcript:
        return 0

    tokens = C.estimate_tokens(transcript)
    if not C.should_run(cfg, trigger, tokens):
        _emit({"suppressOutput": True})
        return 0

    transcript = C.clip_transcript(transcript, cfg["max_prompt_chars"])

    prompt, mode = C.build_prompt(transcript, cfg)
    try:
        if mode == "extractive":
            reply = bridge.complete(
                prompt, tier=cfg["model_tier"], max_tokens=400,
                temperature=0.1, port=cfg["bridge_port"],
            )
            compacted = C.reconstruct_extractive(transcript, reply)
            if compacted is None:
                # Extractive selection unparseable — fall back to a rewrite so
                # the user still gets a local summary.
                ab_cfg = dict(cfg, type="abstractive")
                ab_prompt, _ = C.build_prompt(transcript, ab_cfg)
                compacted = bridge.complete(
                    ab_prompt, tier=cfg["model_tier"],
                    max_tokens=_abstractive_max_tokens(cfg, transcript),
                    temperature=0.3, port=cfg["bridge_port"],
                )
                mode = "abstractive (fallback)"
        else:
            compacted = bridge.complete(
                prompt, tier=cfg["model_tier"],
                max_tokens=_abstractive_max_tokens(cfg, transcript),
                temperature=0.3, port=cfg["bridge_port"],
            )
    except bridge.BridgeError as exc:
        sys.stderr.write(f"halen-local-compaction: {exc}\n")
        return 0

    compacted = (compacted or "").strip()
    if not compacted:
        return 0

    stats = C.compaction_stats(transcript, compacted)
    _save_summary(root, session_id, compacted, {
        "session_id": session_id, "trigger": trigger, "mode": mode, **stats,
    })
    _emit({"systemMessage": C.summary_message(stats, mode), "suppressOutput": False})
    return 0


def _abstractive_max_tokens(cfg: dict, transcript: str) -> int:
    budget = C.target_token_budget(cfg, C.estimate_tokens(transcript))
    return max(256, min(4096, round(budget * 1.3)))


if __name__ == "__main__":
    sys.exit(main())
