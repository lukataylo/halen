#!/usr/bin/env bash
set -euo pipefail

# One command, end-to-end: build → notarize → DMG → appcast → GitHub release.
# Run from a clean working tree on the commit you want to release.
#
# What it does:
#   1. Reads the current version from Resources/Info.plist
#   2. Calls build-app.sh (DIST=1) → signed .app
#   3. Calls notarize.sh → stapled .app
#   4. Calls package-dmg.sh → notarized + stapled DMG
#   5. Regenerates appcast.xml from build/ via Sparkle's generate_appcast
#   6. Uploads the DMG to the GitHub release matching the version
#   7. Commits + pushes the updated appcast.xml so halen.dev picks it up
#
# Required env: SIGN_IDENTITY (the Developer ID Application cert hash) and
# NOTARY_PROFILE (already stored — see docs/RELEASING.md).
#
# See docs/RELEASING.md for the one-time setup (cert + app-specific password
# + keychain profile + Sparkle keypair).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
DMG_PATH="$ROOT/build/Halen-$VERSION.dmg"
APPCAST="$ROOT/appcast.xml"
RELEASE_TAG="${RELEASE_TAG:-v$VERSION}"
GH_REPO="${GH_REPO:-lukataylo/halen}"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    echo "error: SIGN_IDENTITY not set — see docs/RELEASING.md §1" >&2
    exit 1
fi

# Locate Sparkle's generate_appcast in the SwiftPM artifact cache. It's not
# on PATH by default; this is the canonical install location after
# `swift package resolve`.
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [[ ! -x "$SPARKLE_BIN" ]]; then
    echo "error: generate_appcast not found at $SPARKLE_BIN" >&2
    echo "       run 'swift package resolve' first" >&2
    exit 1
fi

# --- build + sign + notarize + DMG ----------------------------------------

echo "═══ Halen v$VERSION release pipeline ═══"
echo

DIST=1 SIGN_IDENTITY="$SIGN_IDENTITY" "$ROOT/scripts/build-app.sh"
"$ROOT/scripts/notarize.sh"
SIGN_IDENTITY="$SIGN_IDENTITY" "$ROOT/scripts/package-dmg.sh"

if [[ ! -f "$DMG_PATH" ]]; then
    echo "error: expected $DMG_PATH not produced" >&2
    exit 1
fi

# --- appcast --------------------------------------------------------------

# generate_appcast walks a directory of DMGs and emits an appcast.xml that
# references them. We pass the build dir directly; only the current
# version's DMG lives there, so the output is naturally a single-item feed
# (with any prior versions Sparkle finds in the directory layered in).
#
# `--ed-key-file -` would let us pipe the private key; instead we let the
# tool find the EdDSA key in the maintainer's keychain (where
# `generate_keys` stored it on first run). No private key ever lives in
# the repo.
echo
echo "→ regenerating appcast.xml"
"$SPARKLE_BIN" \
    --download-url-prefix "https://github.com/$GH_REPO/releases/download/$RELEASE_TAG/" \
    "$ROOT/build"

# generate_appcast writes the appcast next to its input — move it to the
# canonical repo-root location that halen.dev serves.
if [[ -f "$ROOT/build/appcast.xml" ]]; then
    mv "$ROOT/build/appcast.xml" "$APPCAST"
    echo "✓ appcast.xml updated"
else
    echo "warning: generate_appcast did not produce build/appcast.xml" >&2
fi

# --- GitHub release upload ------------------------------------------------

if command -v gh >/dev/null 2>&1; then
    if gh release view "$RELEASE_TAG" -R "$GH_REPO" >/dev/null 2>&1; then
        echo
        echo "→ uploading $DMG_PATH to GitHub release $RELEASE_TAG"
        # Upload twice — once with the version suffix (canonical filename),
        # once without (matches the hardcoded URL on halen.dev). --clobber
        # replaces any prior upload with the same name.
        gh release upload "$RELEASE_TAG" "$DMG_PATH" --clobber -R "$GH_REPO"
        cp "$DMG_PATH" "/tmp/Halen.dmg"
        gh release upload "$RELEASE_TAG" "/tmp/Halen.dmg" --clobber -R "$GH_REPO"
        rm -f /tmp/Halen.dmg
    else
        echo
        echo "note: GitHub release $RELEASE_TAG doesn't exist yet — create it with"
        echo "      gh release create $RELEASE_TAG -R $GH_REPO --title 'Halen $VERSION' --notes-file CHANGELOG.md"
        echo "      then rerun this script (it's idempotent)."
    fi
else
    echo "note: gh CLI not installed; upload $DMG_PATH manually to release $RELEASE_TAG."
fi

# --- summary --------------------------------------------------------------

echo
echo "═══ release artefacts ═══"
echo "  DMG:     $DMG_PATH"
echo "  appcast: $APPCAST"
echo
echo "Next:"
echo "  1. Commit the updated appcast.xml — halen.dev serves it on the next push."
echo "  2. Verify users can update: launch the prior version, watch it pick up v$VERSION."
echo "  3. Update the changelog page if you haven't already."
