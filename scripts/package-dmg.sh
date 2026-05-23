#!/usr/bin/env bash
set -euo pipefail

# Full release flow (this script is step 3 of 3): see docs/RELEASING.md
# for the end-to-end pipeline, prerequisites, and troubleshooting table.
#
# Package the stapled Developer-ID build as a notarized, drag-to-Install DMG.
#
# Inputs:  build/Halen.app          (must already be notarized + stapled by
#                                    scripts/notarize.sh, otherwise users
#                                    will see a Gatekeeper warning on first
#                                    launch even though the DMG itself is
#                                    accepted)
# Outputs: build/Halen-<version>.dmg  (signed + notarized + stapled)
#
# Why notarize the DMG too — `notarytool` ticketing the .app inside is
# enough for the *app* to launch cleanly once the user copies it to
# /Applications, but Safari/Chrome attach a quarantine xattr to the .dmg
# download itself. If the DMG isn't notarized & stapled, the first
# double-click shows "Apple could not verify Halen.dmg" and the user has
# to right-click → Open. Stapling the DMG removes that prompt entirely.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_DIR="$ROOT/build/Halen.app"
# Resolve the symlinked staging path (see notarize.sh for context).
# `ditto` copies the symlink-as-symlink rather than the bundle behind it
# unless we follow first; the DMG would then be empty.
if [[ -L "$APP_DIR" ]]; then
    APP_DIR="$(readlink "$APP_DIR")"
fi
INFO_PLIST="$APP_DIR/Contents/Info.plist"

# Reuse the same keychain profile as notarize.sh. Override per-call with
# NOTARY_PROFILE=… if you have multiple stored profiles.
NOTARY_PROFILE="${NOTARY_PROFILE:-halen-notary}"

# Default to the same Developer ID Application cert used to sign the .app —
# any cert with that string is fine; override with SIGN_IDENTITY=<hash> if
# the bare name is ambiguous in your keychain (multiple certs).
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"

# --- preflight -------------------------------------------------------------

if [[ ! -d "$APP_DIR" ]]; then
    echo "error: $APP_DIR not found — run scripts/notarize.sh first" >&2
    exit 1
fi

# Refuse to package an unstapled .app. The DMG would be notarized and
# stapled, but the .app inside would still trigger Gatekeeper warnings
# once the user copies it to /Applications. Fail loudly instead.
if ! xcrun stapler validate "$APP_DIR" >/dev/null 2>&1; then
    echo "error: $APP_DIR has no stapled notarization ticket" >&2
    echo "       run scripts/notarize.sh first" >&2
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "error: notarytool keychain profile \"$NOTARY_PROFILE\" not found." >&2
    echo "       see scripts/notarize.sh for setup instructions." >&2
    exit 1
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
DMG_PATH="$ROOT/build/Halen-$VERSION.dmg"
STAGING="$ROOT/build/dmg-staging"
VOLNAME="Halen $VERSION"

# --- assemble layout -------------------------------------------------------

echo "→ assembling DMG staging at $STAGING"
rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"

# Copy the .app — `ditto` preserves the code signature and any extended
# attributes (including the stapled notarization ticket). `cp -R` would
# work for the bits but ditto is the path Apple recommends for signed
# bundles.
ditto "$APP_DIR" "$STAGING/Halen.app"

# Drag-target: a symlink to /Applications next to Halen.app turns the DMG
# into a one-gesture install — the user drags Halen onto Applications and
# the system copies it. The link is a relative `/Applications` so it
# resolves on the user's Mac, not yours.
ln -s /Applications "$STAGING/Applications"

# --- create + sign DMG -----------------------------------------------------

echo "→ creating $DMG_PATH"
# UDZO = zlib-compressed, read-only, the standard for distribution. -ov
# overwrites any prior file (already deleted above; defensive). -volname
# sets the title bar of the mounted volume.
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo "→ signing DMG with: $SIGN_IDENTITY"
# Hardened Runtime and entitlements are properties of Mach-Os, not DMGs —
# the DMG just needs a Developer ID signature so notarytool can verify the
# distributor before accepting it for notarization.
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

# --- notarize + staple -----------------------------------------------------

echo "→ submitting DMG to Apple notary service (typically 1–5 min)…"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "→ stapling ticket to $DMG_PATH"
# Stapling the DMG embeds the notarization ticket so it launches cleanly
# offline on the user's Mac (Gatekeeper otherwise needs network access to
# verify with Apple on first open).
xcrun stapler staple "$DMG_PATH"

echo "→ verifying"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

# --- cleanup ---------------------------------------------------------------

rm -rf "$STAGING"

echo
echo "✓ packaged $DMG_PATH"
echo "  size: $(du -h "$DMG_PATH" | cut -f1)"
echo "  share this file — first launch on a fresh Mac needs no right-click,"
echo "  no Settings → Security override, no network."
