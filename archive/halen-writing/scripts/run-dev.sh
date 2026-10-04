#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-app.sh"

# Quit any prior instance so the rebuilt bundle takes effect on relaunch.
osascript -e 'tell application "Halen" to quit' >/dev/null 2>&1 || true
pkill -f "Halen.app/Contents/MacOS/halen" >/dev/null 2>&1 || true
sleep 0.5

# Launch via LaunchServices so TCC treats Halen as its own subject.
# Running the binary directly from the shell makes macOS attribute AX trust to the
# parent terminal — Halen never appears in System Settings → Accessibility that way.
open "$ROOT/build/Halen.app"

echo "✓ launched Halen — streaming logs (Ctrl+C to detach; app keeps running)"
echo
exec log stream --level debug --predicate 'subsystem == "com.dadiani.halen"'
