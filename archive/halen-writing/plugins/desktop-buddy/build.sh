#!/usr/bin/env bash
# Build the Swift companion binary and stage it at ./bin/DesktopBuddy where
# plugin.py looks for it first. Run this from the plugin directory.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/companion"

echo "› swift build -c release"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/DesktopBuddy"
if [ ! -x "$BIN_PATH" ]; then
  echo "build.sh: expected binary at $BIN_PATH but it is missing or not executable" >&2
  exit 1
fi

mkdir -p "$HERE/bin"
ln -sf "$BIN_PATH" "$HERE/bin/DesktopBuddy"
echo "› staged $HERE/bin/DesktopBuddy -> $BIN_PATH"
