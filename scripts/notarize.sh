#!/usr/bin/env bash
set -euo pipefail

# Notarize the Developer ID build produced by `DIST=1 ./scripts/build-app.sh`:
# zip it, submit to Apple's notary service, staple the ticket, verify, and
# package the stapled app as the distributable zip.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_DIR="$ROOT/build/Halen.app"
INFO_PLIST="$APP_DIR/Contents/Info.plist"

# notarytool credentials profile, stored once in the login keychain with:
#   xcrun notarytool store-credentials "halen-notary" \
#     --apple-id "<your Apple ID email>" \
#     --team-id  "<your 10-char Team ID>" \
#     --password "<app-specific password from appleid.apple.com>"
NOTARY_PROFILE="${NOTARY_PROFILE:-halen-notary}"

# --- preflight -------------------------------------------------------------

if [[ ! -d "$APP_DIR" ]]; then
    echo "error: $APP_DIR not found — run 'DIST=1 ./scripts/build-app.sh' first" >&2
    exit 1
fi

# Refuse to notarize a dev build. Notarization only accepts Developer ID +
# Hardened Runtime; an Apple Development signature is rejected by Apple after a
# slow round-trip, so fail fast and locally instead.
SIG_AUTHORITY="$(codesign -dvv "$APP_DIR" 2>&1 | grep '^Authority=' | head -1 || true)"
if [[ "$SIG_AUTHORITY" != *"Developer ID Application"* ]]; then
    echo "error: $APP_DIR is not Developer ID signed (got: ${SIG_AUTHORITY:-none})" >&2
    echo "       rebuild with: DIST=1 ./scripts/build-app.sh" >&2
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    cat >&2 <<EOF
error: notarytool keychain profile "$NOTARY_PROFILE" not found.
Create it once with:

  xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
    --apple-id "<your Apple ID email>" \\
    --team-id  "<your 10-char Team ID>" \\
    --password "<app-specific password from appleid.apple.com>"

Then re-run this script. Override the profile name with NOTARY_PROFILE=...
EOF
    exit 1
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
ZIP_FOR_NOTARY="$ROOT/build/Halen-notary.zip"
DIST_ZIP="$ROOT/build/Halen-$VERSION.zip"

# --- submit ----------------------------------------------------------------

echo "→ zipping app for notarization"
rm -f "$ZIP_FOR_NOTARY"
# --keepParent so the archive contains Halen.app/ at its root, as Apple expects.
ditto -c -k --keepParent "$APP_DIR" "$ZIP_FOR_NOTARY"

echo "→ submitting to Apple notary service (typically 1–5 min)…"
# --wait blocks until Apple finishes and exits non-zero on rejection. If it
# reports "Invalid", inspect the details with:
#   xcrun notarytool log <submission-id> --keychain-profile "$NOTARY_PROFILE"
xcrun notarytool submit "$ZIP_FOR_NOTARY" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

# --- staple + verify -------------------------------------------------------

echo "→ stapling ticket to $APP_DIR"
xcrun stapler staple "$APP_DIR"

echo "→ verifying"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
# Must report "accepted" with "source=Notarized Developer ID".
spctl --assess --type execute --verbose=2 "$APP_DIR"
xcrun stapler validate "$APP_DIR"

# --- package the stapled app as the distributable -------------------------

echo "→ packaging $DIST_ZIP"
rm -f "$DIST_ZIP" "$ZIP_FOR_NOTARY"
# Re-zip *after* stapling so the downloaded artifact carries the ticket and
# launches offline on first run.
ditto -c -k --keepParent "$APP_DIR" "$DIST_ZIP"

echo "✓ notarized, stapled, and packaged: $DIST_ZIP"
echo "  next: scripts/package-dmg.sh   (creates a drag-to-Install, notarized DMG)"
