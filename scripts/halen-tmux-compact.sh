#!/usr/bin/env bash
# Capture the current tmux pane's scrollback, compact the reasoning chain in it,
# and show the result in a popup. Bind it in ~/.tmux.conf (per-pane, on-demand):
#
#   bind-key C-k run-shell '~/Documents/halen/scripts/halen-tmux-compact.sh #{pane_id}'
#
# Then: prefix + Ctrl-k. Reads HALEN_COMPACT_* env vars (model, ratio, mode) the
# same as halen-compact.py. Needs Ollama running locally.
#
# Note: this compacts reasoning a tool *prints* into the pane (deepseek-r1 / qwen
# <think>…</think>, `ollama run`, etc.). Claude Code's own thinking is redacted in
# its transcript and lives on the alt-screen, so it can't be captured this way.
set -euo pipefail

pane="${1:-$(tmux display-message -p '#{pane_id}')}"
lines="${HALEN_COMPACT_SCROLLBACK:-3000}"
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -t halen-compact)"
# Clean up the tempfile even if display-popup is unavailable or we're interrupted
# before it opens. The in-popup `rm -f` below is idempotent, so this is harmless.
trap 'rm -f "$tmp"' EXIT

# Capture in the outer shell so the right pane id is used, then compact to a file.
tmux capture-pane -p -S "-${lines}" -t "$pane" \
  | python3 "$here/halen-compact.py" --detect --stats >"$tmp" 2>&1 || true
[ -s "$tmp" ] || printf '%s\n' "[halen-compact] No reasoning chain found in pane." >"$tmp"

# Show in a popup (own screen — never clobbers the pane). q to close.
tmux display-popup -h 80% -w 80% -E "less -R '$tmp'; rm -f '$tmp'"
