#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# DIST=1 produces a notarization-ready build: release config, Developer ID
# signing, Hardened Runtime, a secure timestamp, and the app entitlements.
# Default (DIST unset) is a fast local dev build signed with the Apple
# Development cert — no Hardened Runtime, and TCC permissions persist across
# rebuilds. After a DIST build, run scripts/notarize.sh.
DIST="${DIST:-0}"

if [[ "$DIST" == "1" ]]; then
    CONFIG="${CONFIG:-release}"
    # The Developer ID Application certificate. Create it once at
    # developer.apple.com (Certificates → +) and download it into the login
    # keychain; codesign matches this as a substring. Override with
    # SIGN_IDENTITY=... if you have more than one and the match is ambiguous.
    SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
else
    CONFIG="${CONFIG:-debug}"
    # Stable across rebuilds so granted TCC (Accessibility, etc.) permissions
    # stick. Override with SIGN_IDENTITY=- for ad-hoc.
    SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development: luka dadiani (75R33YUT6M)}"
fi

APP_DIR="$ROOT/build/Halen.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"
ENTITLEMENTS="$ROOT/Resources/Halen.entitlements"

echo "→ swift build -c $CONFIG  (dist=$DIST)"
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
               HalenIndicator.png HalenIndicator@2x.png HalenIndicator@3x.png \
               HalenOutline.png HalenOutline@2x.png HalenOutline@3x.png; do
    if [[ -f "$ROOT/Resources/$variant" ]]; then
        cp "$ROOT/Resources/$variant" "$RESOURCES/$variant"
    fi
done

# Embed the llama.cpp dynamic framework. `swift build` links the binary against
# @rpath/llama.framework/...; without this the assembled bundle fails to launch
# with a dyld "Library not loaded" error.
LLAMA_FW_SRC="$ROOT/Vendor/llama.xcframework/macos-arm64/llama.framework"
if [[ -d "$LLAMA_FW_SRC" ]]; then
    echo "→ embedding llama.framework"
    mkdir -p "$FRAMEWORKS"
    ditto "$LLAMA_FW_SRC" "$FRAMEWORKS/llama.framework"
    # The freshly-copied binary only has SwiftPM's @loader_path rpath; point it
    # at Contents/Frameworks/ the conventional way. Must happen before signing —
    # codesign seals the binary, so any later mutation invalidates the signature.
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/halen"
else
    echo "warning: $LLAMA_FW_SRC not found — run scripts/fetch-assets.sh" >&2
fi

# Bundling the GGUF inflates the .app from ~12 MB to ~780 MB. Default OFF —
# `ModelDownloader` fetches the file on demand into Application Support, so
# the .app users download stays small. Opt-in with BUNDLE_MODEL=1 for an
# offline-first / kiosk-friendly all-in-one build.
BUNDLE_MODEL="${BUNDLE_MODEL:-0}"
if [[ "$BUNDLE_MODEL" == "1" ]]; then
    GGUF_SRC="$ROOT/assets/Models/gemma-4-E4B-it-Q4_K_M.gguf"
    if [[ -f "$GGUF_SRC" ]]; then
        echo "→ bundling $(basename "$GGUF_SRC") (BUNDLE_MODEL=1)"
        mkdir -p "$RESOURCES/Models"
        ditto "$GGUF_SRC" "$RESOURCES/Models/$(basename "$GGUF_SRC")"
    else
        echo "warning: $GGUF_SRC not found — run scripts/fetch-assets.sh" >&2
    fi
else
    echo "→ slim build (no GGUF); ModelDownloader will fetch on first use"
fi

# Sign nested code (the framework) before the app so the app seals a valid
# signature. No --deep (deprecated; doesn't handle nested code correctly).
echo "→ signing with: $SIGN_IDENTITY"
if [[ "$DIST" == "1" ]]; then
    # Every Mach-O in a notarized bundle must opt into the Hardened Runtime and
    # carry a secure timestamp. The framework gets runtime + timestamp; the app
    # additionally gets Halen's entitlements (mic, calendar). The framework does
    # NOT get app entitlements — it has none of its own.
    if [[ ! -f "$ENTITLEMENTS" ]]; then
        echo "error: $ENTITLEMENTS not found — required for a DIST build" >&2
        exit 1
    fi
    if [[ -d "$FRAMEWORKS/llama.framework" ]]; then
        codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" "$FRAMEWORKS/llama.framework"
    fi
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" --identifier com.dadiani.halen "$APP_DIR"

    echo "→ verifying signature"
    codesign --verify --strict --verbose=2 "$APP_DIR"
    echo "✓ built + signed $APP_DIR"
    echo "  next: scripts/notarize.sh   (Gatekeeper will reject it until then)"
else
    if [[ -d "$FRAMEWORKS/llama.framework" ]]; then
        codesign --force --sign "$SIGN_IDENTITY" "$FRAMEWORKS/llama.framework" >/dev/null
    fi
    codesign --force --sign "$SIGN_IDENTITY" --identifier com.dadiani.halen "$APP_DIR" >/dev/null
    echo "✓ built $APP_DIR"
fi
