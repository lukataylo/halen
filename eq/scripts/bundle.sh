#!/bin/zsh
# Quick local dev bundle (ad-hoc signed). For a signed, notarized release
# with the DMG installer and appcast, use scripts/release.sh.
#   CONFIG=debug ./scripts/bundle.sh && open .build/HalenEQ.app
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-release}
swift build -c "$CONFIG" --product halen-eq
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP=.build/HalenEQ.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/halen-eq" "$APP/Contents/MacOS/HalenEQ"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns Resources/HalenMenubar*.png Resources/Doto.ttf Resources/Doto-OFL.txt "$APP/Contents/Resources/"
for b in "$BIN"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/HalenEQ" 2>/dev/null || true
codesign --force --deep --sign - "$APP"
echo "Built $APP"
