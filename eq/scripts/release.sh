#!/bin/zsh
# Halen EQ release: build → sign (Developer ID, Hardened Runtime) → notarize
# → staple → DMG installer → notarize DMG → EdDSA-signed appcast entry.
#
#   SIGN_IDENTITY=<sha1> ./scripts/release.sh            # full release
#   NOTARIZE=0 SIGN_IDENTITY=<sha1> ./scripts/release.sh # signed, not notarized
#
# Outputs (in dist/): "Halen EQ.app", HalenEQ-<version>.dmg, and an updated
# ../eq/appcast.xml served at https://halen.dev/eq/appcast.xml.
#
# One-time setup is shared with the archived Halen app — see
# archive/halen-writing/docs/RELEASING.md (Developer ID cert, the
# `halen-notary` notarytool profile, Sparkle EdDSA key in the keychain).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

: "${SIGN_IDENTITY:?set SIGN_IDENTITY to your Developer ID Application hash (security find-identity -v -p codesigning)}"
NOTARIZE="${NOTARIZE:-1}"
NOTARY_PROFILE="${NOTARY_PROFILE:-halen-notary}"
GH_REPO="${GH_REPO:-lukataylo/halen}"

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist)"
BUILD="$(plutil -extract CFBundleVersion raw -o - Resources/Info.plist)"
TAG="eq-v$VERSION"
DIST="$ROOT/dist"
# Stage outside any iCloud-synced folder: the fileprovider re-stamps
# FinderInfo xattrs, which codesign rejects.
STAGE="$(mktemp -d /tmp/halen-eq-release.XXXX)"
APP="$STAGE/Halen EQ.app"
DMG="$DIST/HalenEQ-$VERSION.dmg"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"

echo "═══ Halen EQ $VERSION ($BUILD) ═══"

echo "→ build"
swift build -c release --product halen-eq
BIN="$(swift build -c release --show-bin-path)"

echo "→ assemble"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$DIST"
cp "$BIN/halen-eq" "$APP/Contents/MacOS/HalenEQ"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/HalenMenubar*.png Resources/Doto.ttf Resources/Doto-OFL.txt "$APP/Contents/Resources/"
for b in "$BIN"/*.bundle(N); do ditto "$b" "$APP/Contents/Resources/$(basename "$b")"; done
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/HalenEQ"
xattr -cr "$APP"

echo "→ sign ($SIGN_IDENTITY)"
sign() { codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@"; }
SP="$APP/Contents/Frameworks/Sparkle.framework"
# Sparkle's nested helpers first (deepest first), then the framework, then the app.
for nested in "$SP/Versions/B/XPCServices/Installer.xpc" "$SP/Versions/B/XPCServices/Downloader.xpc" \
              "$SP/Versions/B/Autoupdate" "$SP/Versions/B/Updater.app"; do
    [[ -e "$nested" ]] && sign "$nested"
done
sign "$SP"
sign --entitlements Resources/HalenEQ.entitlements "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

notarize() {   # $1 = file to submit
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

if [[ "$NOTARIZE" == "1" ]]; then
    echo "→ notarize app"
    ditto -c -k --keepParent "$APP" "$STAGE/app.zip"
    notarize "$STAGE/app.zip"
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose "$APP"
fi

echo "→ DMG installer"
DMG_SRC="$STAGE/dmg"
mkdir -p "$DMG_SRC"
ditto "$APP" "$DMG_SRC/Halen EQ.app"
ln -s /Applications "$DMG_SRC/Applications"
rm -f "$DMG"
hdiutil create -volname "Halen EQ" -srcfolder "$DMG_SRC" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
if [[ "$NOTARIZE" == "1" ]]; then
    echo "→ notarize DMG"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi
ditto "$APP" "$DIST/Halen EQ.app"

echo "→ appcast"
SIG_LINE="$("$SPARKLE_BIN/sign_update" "$DMG")"   # sparkle:edSignature="…" length="…"
URL="https://github.com/$GH_REPO/releases/download/$TAG/HalenEQ-$VERSION.dmg"
cat > appcast.xml <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>Halen EQ</title>
        <item>
            <title>$VERSION</title>
            <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
            <enclosure url="$URL" type="application/octet-stream" $SIG_LINE/>
        </item>
    </channel>
</rss>
XML

rm -rf "$STAGE"
echo
echo "✓ $DMG"
echo "✓ eq/appcast.xml → publish with: gh release create $TAG \"$DMG\" -R $GH_REPO"
[[ "$NOTARIZE" == "1" ]] || echo "⚠ not notarized — Gatekeeper will warn. Re-run with NOTARIZE=1 before publishing."
