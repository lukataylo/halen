#!/usr/bin/env bash
set -euo pipefail

# Full release flow (this script is step 1 of 3): see docs/RELEASING.md
# for the end-to-end pipeline, prerequisites, and troubleshooting table.

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

# When the repo lives inside an iCloud-synced folder (Documents, Desktop)
# the fileprovider keeps re-stamping `com.apple.FinderInfo` on the assembled
# bundle and its nested framework. codesign rejects that as
# "resource fork, Finder information, or similar detritus not allowed", and
# nothing short of staging the build outside iCloud reliably escapes the
# race. So: detect iCloud (parent dir tagged with the fileprovider xattr)
# and stage to /tmp/halen-build/ when present. A `build/Halen.app` symlink
# at the canonical location keeps `run-dev.sh` and the user's muscle memory
# pointing at the right place.
#
# Override with OUT_DIR=… to force a specific staging directory (e.g. CI).
parent_dir="$(dirname "$ROOT")"
icloud_detected=0
if xattr "$parent_dir" 2>/dev/null | grep -q 'com.apple.fileprovider'; then
    icloud_detected=1
fi
if [[ -n "${OUT_DIR:-}" ]]; then
    APP_DIR="$OUT_DIR/Halen.app"
elif [[ "$icloud_detected" == "1" ]]; then
    APP_DIR="/tmp/halen-build/Halen.app"
    echo "→ iCloud-synced parent detected — staging to $APP_DIR"
else
    APP_DIR="$ROOT/build/Halen.app"
fi
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

# Embed Sparkle.framework (the auto-updater). Pulled in via SwiftPM; the
# xcframework lives in .build/artifacts/. Without this, the .app crashes at
# UpdaterController.init() with a Sparkle dyld error.
SPARKLE_FW_SRC="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ -d "$SPARKLE_FW_SRC" ]]; then
    echo "→ embedding Sparkle.framework"
    mkdir -p "$FRAMEWORKS"
    ditto "$SPARKLE_FW_SRC" "$FRAMEWORKS/Sparkle.framework"
else
    echo "warning: $SPARKLE_FW_SRC not found — run 'swift package resolve'" >&2
fi

# Bundling the GGUF inflates the .app from ~12 MB to ~4.8 GB. Default OFF —
# `ModelDownloader` fetches the file on demand into Application Support, so
# the .app users download stays small. Opt-in with BUNDLE_MODEL=1 for an
# offline-first / kiosk-friendly all-in-one build.
BUNDLE_MODEL="${BUNDLE_MODEL:-0}"
if [[ "$BUNDLE_MODEL" == "1" ]]; then
    GGUF_SRC="$ROOT/assets/Models/gemma-4-E4B-it-IQ4_XS.gguf"
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
# Each codesign call is preceded by its own `xattr -cr` to defeat iCloud's
# FinderInfo re-stamping (see the staging block at the top of this script).
echo "→ signing with: $SIGN_IDENTITY"

# Pre-flight: codesign prompts for keychain access on every signed binary
# unless the signing key's partition list authorises `codesign:`. This
# script signs 8 things per build (llama, 4 Sparkle sub-bundles, Sparkle,
# the app); without the partition list, that's 8 password dialogs every
# build. With it, 0.
#
# setup-signing-keychain.sh does the one-time fix and drops a marker file
# scoped to the identity hash. We refuse to start the codesign loop until
# that marker exists so the user never eats 8 dialogs without realising
# the setup script would have prevented it.
SETUP_MARKER_DIR="$HOME/.cache/halen"
# Hash the identity string into a stable suffix — different identities
# (dev vs DIST) need separate setup, so they get separate markers.
SETUP_MARKER="$SETUP_MARKER_DIR/.signing-keychain-configured-$(printf '%s' "$SIGN_IDENTITY" | shasum -a 256 | cut -c1-16)"
if [[ "$SIGN_IDENTITY" != "-" ]] && [[ ! -f "$SETUP_MARKER" ]]; then
    echo "" >&2
    echo "error: codesign keychain setup hasn't run for this identity." >&2
    echo "  Without it, every signed binary triggers a keychain prompt." >&2
    echo "  This build signs 8 things — you'd see the dialog 8 times." >&2
    echo "" >&2
    echo "  Fix (one time, ~10 seconds — one password prompt total):" >&2
    echo "    SIGN_IDENTITY=\"$SIGN_IDENTITY\" ./scripts/setup-signing-keychain.sh" >&2
    echo "" >&2
    echo "  After that, build-app.sh runs without any prompts." >&2
    echo "" >&2
    echo "  Already ran it? Re-run to refresh the marker:" >&2
    echo "    SIGN_IDENTITY=\"$SIGN_IDENTITY\" ./scripts/setup-signing-keychain.sh" >&2
    exit 1
fi
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
        xattr -cr "$FRAMEWORKS/llama.framework" 2>/dev/null || true
        codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" "$FRAMEWORKS/llama.framework"
    fi
    if [[ -d "$FRAMEWORKS/Sparkle.framework" ]]; then
        # Sparkle ships nested helper bundles (Autoupdate, Updater) that must
        # each be signed individually; their internal symlinks make a single
        # top-level codesign call insufficient. Sign deepest-first.
        sparkle="$FRAMEWORKS/Sparkle.framework"
        for nested in \
            "$sparkle/Versions/B/XPCServices/Installer.xpc" \
            "$sparkle/Versions/B/XPCServices/Downloader.xpc" \
            "$sparkle/Versions/B/Autoupdate" \
            "$sparkle/Versions/B/Updater.app"; do
            [[ -e "$nested" ]] || continue
            xattr -cr "$nested" 2>/dev/null || true
            codesign --force --options runtime --timestamp \
                --sign "$SIGN_IDENTITY" "$nested"
        done
        xattr -cr "$sparkle" 2>/dev/null || true
        codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" "$sparkle"
    fi
    xattr -cr "$APP_DIR" 2>/dev/null || true
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" --identifier com.dadiani.halen "$APP_DIR"

    echo "→ verifying signature"
    codesign --verify --strict --verbose=2 "$APP_DIR"
    echo "✓ built + signed $APP_DIR"
    echo "  next: scripts/notarize.sh   (Gatekeeper will reject it until then)"
else
    # `codesign` failing here (commonly `errSecInternalComponent` — a wedged
    # `securityd`) leaves an unsigned bundle. macOS then treats it as a new
    # identity and the app's TCC permissions don't carry over. Catch the
    # failure and point at the fix instead of dying with a raw Security error.
    codesign_failed() {
        echo "" >&2
        echo "error: codesign failed — the bundle is unsigned." >&2
        echo "  This is usually a wedged 'securityd' (errSecInternalComponent)." >&2
        echo "  Fix: reboot (clears securityd), or 'sudo killall securityd', then rebuild." >&2
        echo "  After any signature change, run scripts/reset-permissions.sh so TCC" >&2
        echo "  re-prompts cleanly." >&2
        exit 1
    }
    # Clear xattrs *immediately before each* codesign call. iCloud's
    # fileprovider re-stamps `com.apple.FinderInfo` over seconds, not
    # milliseconds, so the sub-ms window between clear and sign is safe — but
    # the gap between the framework sign and the app sign is enough for it to
    # re-add. Clear twice.
    if [[ -d "$FRAMEWORKS/llama.framework" ]]; then
        xattr -cr "$FRAMEWORKS/llama.framework" 2>/dev/null || true
        codesign --force --sign "$SIGN_IDENTITY" "$FRAMEWORKS/llama.framework" >/dev/null || codesign_failed
    fi
    if [[ -d "$FRAMEWORKS/Sparkle.framework" ]]; then
        sparkle="$FRAMEWORKS/Sparkle.framework"
        for nested in \
            "$sparkle/Versions/B/XPCServices/Installer.xpc" \
            "$sparkle/Versions/B/XPCServices/Downloader.xpc" \
            "$sparkle/Versions/B/Autoupdate" \
            "$sparkle/Versions/B/Updater.app"; do
            [[ -e "$nested" ]] || continue
            xattr -cr "$nested" 2>/dev/null || true
            codesign --force --sign "$SIGN_IDENTITY" "$nested" >/dev/null || codesign_failed
        done
        xattr -cr "$sparkle" 2>/dev/null || true
        codesign --force --sign "$SIGN_IDENTITY" "$sparkle" >/dev/null || codesign_failed
    fi
    xattr -cr "$APP_DIR" 2>/dev/null || true
    codesign --force --sign "$SIGN_IDENTITY" --identifier com.dadiani.halen "$APP_DIR" >/dev/null || codesign_failed
    echo "✓ built $APP_DIR"
fi

# Back-compat symlink: when the build was staged to /tmp (iCloud avoidance),
# keep `$ROOT/build/Halen.app` pointing at the real bundle so run-dev.sh and
# any other tooling still finds it without changes.
if [[ "$APP_DIR" != "$ROOT/build/Halen.app" ]]; then
    mkdir -p "$ROOT/build"
    rm -rf "$ROOT/build/Halen.app"
    ln -s "$APP_DIR" "$ROOT/build/Halen.app"
    echo "✓ symlinked $ROOT/build/Halen.app -> $APP_DIR"
fi
