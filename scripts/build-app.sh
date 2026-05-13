#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-debug}"
APP_DIR="$ROOT/build/Halen.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "→ swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN_PATH="$BIN_DIR/halen"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "error: build did not produce $BIN_PATH" >&2
    exit 1
fi

echo "→ assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES"
cp "$BIN_PATH" "$MACOS_DIR/halen"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

# Ad-hoc sign so the bundle's TCC identity (Accessibility grant) is stable across rebuilds.
codesign --force --sign - --identifier com.dadiani.halen "$APP_DIR" >/dev/null

echo "✓ built $APP_DIR"
