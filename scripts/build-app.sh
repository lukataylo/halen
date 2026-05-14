#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-debug}"
APP_DIR="$ROOT/build/Halen.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# Signing identity: defaults to the user's Apple Development cert (stable across
# rebuilds — TCC permissions persist). Override with SIGN_IDENTITY=- for ad-hoc.
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development: luka dadiani (75R33YUT6M)}"

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

# Icons
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi
if [[ -d "$ROOT/Resources/Menubar" ]]; then
    cp "$ROOT/Resources/Menubar/HalenMenubar.png" "$RESOURCES/HalenMenubar.png" 2>/dev/null || true
    cp "$ROOT/Resources/Menubar/HalenMenubar@2x.png" "$RESOURCES/HalenMenubar@2x.png" 2>/dev/null || true
    cp "$ROOT/Resources/Menubar/HalenMenubar@3x.png" "$RESOURCES/HalenMenubar@3x.png" 2>/dev/null || true
fi
for variant in HalenLogo.png HalenLogo@2x.png HalenLogo@3x.png \
               HalenIndicator.png HalenIndicator@2x.png HalenIndicator@3x.png; do
    if [[ -f "$ROOT/Resources/$variant" ]]; then
        cp "$ROOT/Resources/$variant" "$RESOURCES/$variant"
    fi
done

# Embed the llama.cpp dynamic framework. `swift build` links the binary against
# @rpath/llama.framework/...; without this the assembled bundle fails to launch
# with a dyld "Library not loaded" error.
LLAMA_FW_SRC="$ROOT/Vendor/llama.xcframework/macos-arm64/llama.framework"
FRAMEWORKS="$CONTENTS/Frameworks"
if [[ -d "$LLAMA_FW_SRC" ]]; then
    echo "→ embedding llama.framework"
    mkdir -p "$FRAMEWORKS"
    ditto "$LLAMA_FW_SRC" "$FRAMEWORKS/llama.framework"
    # The freshly-copied binary only has SwiftPM's @loader_path rpath; point it
    # at Contents/Frameworks/ the conventional way.
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/halen"
else
    echo "warning: $LLAMA_FW_SRC not found — run scripts/fetch-assets.sh" >&2
fi

# Bundle the default local model (Gemma 3 1B GGUF) so inference works with no
# external runtime. ditto, not cp — the macOS-blessed copy that codesign trusts.
GGUF_SRC="$ROOT/Assets/Models/gemma-3-1b-it-Q4_K_M.gguf"
if [[ -f "$GGUF_SRC" ]]; then
    echo "→ bundling $(basename "$GGUF_SRC")"
    mkdir -p "$RESOURCES/Models"
    ditto "$GGUF_SRC" "$RESOURCES/Models/$(basename "$GGUF_SRC")"
else
    echo "warning: $GGUF_SRC not found — run scripts/fetch-assets.sh" >&2
fi

echo "→ signing with: $SIGN_IDENTITY"
# Sign nested code (the framework) before the app so the app seals a valid
# signature. No --deep (deprecated; doesn't handle nested code correctly).
if [[ -d "$FRAMEWORKS/llama.framework" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" "$FRAMEWORKS/llama.framework" >/dev/null
fi
codesign --force --sign "$SIGN_IDENTITY" --identifier com.dadiani.halen "$APP_DIR" >/dev/null

echo "✓ built $APP_DIR"
