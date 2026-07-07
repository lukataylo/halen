# Notch Boss

The former [NotchBar](https://github.com/lukataylo/NotchBar) app, absorbed as
a Halen plugin. It turns the MacBook notch into a live dashboard for coding
agents. Off by default — it enables itself when it finds an existing NotchBar
install to inherit.

Declared capabilities: `notch-overlay`, `process-observation`, `hotkeys`,
`notifications`. Nothing it reads (agent transcripts, git state, its own
socket) leaves the machine.

## What it shows

- **Session cards** — one per live Claude Code / Codex / embedded-terminal
  session: project, model, progress, git branch and change count, context
  window usage, token counts and estimated cost, task timeline.
- **The approval doorbell** — when an agent wants to run a tool, the notch
  expands with the tool description, a full diff preview for edits, the
  question UI for interactive prompts, and Deny/Allow (⌘⇧N / ⌘⇧Y). Auto-
  approve rules per tool category live in the plugin's settings.
- **Tool timeline** — every tool call as a node, tap to expand inline diffs.
- **Embedded terminal** — launch `claude` sessions inside the notch
  (SwiftTerm PTY), or send input to sessions running in Terminal/iTerm/Warp.
- **Conflict detector** — file-lock coordination across multiple concurrent
  agents, with a watcher for external (human/IDE) edits to locked files.

Hotkeys: ⌘⇧C toggle, ⌘⇧Y approve, ⌘⇧N reject, ⌘⇧] / ⌘⇧[ next/previous
session — registered through the host's conflict-checked hotkey registry.

## How the Claude Code integration works

Identical to NotchBar's — byte-for-byte, so existing setups keep working:

- "Set up Claude Code connection" writes a hook script to
  `~/.notchbar/bin/notchbar-hook` and merges `PreToolUse`/`PostToolUse`
  entries into `~/.claude/settings.json` (never touching other tools'
  hooks).
- The hook forwards each event as one JSON line over the Unix socket
  `~/.notchbar/notchbar.sock`. Pre-tool-use events block until you answer
  (or the configurable timeout) — and **fail open**: if Halen isn't
  running, the hook prints `{"decision":"approve"}` and your agent never
  hangs.
- Session details (reasoning, token usage, model) are tailed from the
  transcript JSONL Claude Code names in each hook event; past sessions are
  listed from `~/.claude/projects/`.

The multi-agent coordination MCP server is a self-contained Python script
written to `~/.notchbar/bin/notchbar-mcp` and registered as
`mcpServers.notchbar-coordination` in `~/.claude/settings.json`. It speaks
JSON-RPC over stdio (no port) and exposes `claim_file`, `release_file`,
`list_locks`, `get_context`; state is bridged through
`~/.notchbar/coordination/`.

Codex support is observation-only: a managed `[profiles.notchbar]` block in
`~/.codex/config.toml` and transcript tailing from `~/.codex/sessions/`.

## Migrating from the NotchBar app

Automatic. On first start, Notch Boss imports every NotchBar setting
(auto-approve rules, display toggles, cost alerts, provider enables) from
the old app's preferences — one-shot, existing Halen values win. The hook
paths are unchanged, so agents configured for NotchBar keep ringing the
doorbell in Halen.

**Quit the NotchBar app first**: the approval socket can only have one
listener, and the plugin will warn you if it sees NotchBar still running.
