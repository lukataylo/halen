#!/usr/bin/env python3
"""SessionStart hook — restore Halen's on-device summary on resume.

When a session that we previously compacted starts again — `--resume`,
`--continue`, or the fresh context Claude Code spins up right after a
compaction — we inject the local-model summary saved by `precompact.py` as
additional context. This is how "compaction with only the local model"
actually carries forward: the summary the assistant reads on resume is the one
Halen produced on-device, not a cloud round-trip.

Keyed by `session_id`, so a brand-new, unrelated session gets nothing. Any
failure exits 0 silently — a missing summary must never block a session start.
"""
from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compaction as C  # noqa: E402


def _plugin_root() -> str:
    env = os.environ.get("CLAUDE_PLUGIN_ROOT")
    if env:
        return env
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load_summary(root: str, session_id: str) -> str | None:
    safe = "".join(c for c in session_id if c.isalnum() or c in "-_") or "session"
    path = os.path.join(root, "state", f"{safe}.md")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read().strip() or None
    except OSError:
        return None


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 0
    if not isinstance(payload, dict):
        return 0

    session_id = str(payload.get("session_id") or "")
    if not session_id:
        return 0

    root = _plugin_root()
    cfg = C.load_config_file(os.path.join(root, "config.json"))
    if not cfg.get("inject_on_resume", True):
        return 0

    summary = _load_summary(root, session_id)
    if not summary:
        return 0

    context = (
        "## Halen on-device context summary\n\n"
        "An earlier part of this session was compacted on-device by Halen's "
        "local model (no cloud round-trip). Use this summary to continue:\n\n"
        f"{summary}"
    )
    sys.stdout.write(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": context,
        }
    }))
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
