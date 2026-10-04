#!/bin/zsh
# Mac App Store build: sandboxed, no Sparkle, signed .pkg for App Store Connect.
#
#   ./scripts/appstore.sh                 # build + sign + package (needs certs + profile)
#   UPLOAD=1 ./scripts/appstore.sh        # …and upload with altool (needs API key)
#   SANDBOX_TEST=1 ./scripts/appstore.sh  # local sandboxed test build, Apple Development cert
#
# One-time setup (developer.apple.com + App Store Connect), see docs/APP_STORE.md:
#   1. Certificates: "Apple Distribution" and "Mac Installer Distribution".
#   2. App ID dev.halen.eq; a "Mac App Store Connect" provisioning profile for it,
#      saved as eq/Resources/HalenEQ_AppStore.provisionprofile (not committed).
#   3. An app record in App Store Connect (bundle id dev.halen.eq).
#   4. For UPLOAD=1: an App Store Connect API key (.p8 in ~/.appstoreconnect/private_keys/)
#      and ASC_KEY_ID / ASC_ISSUER_ID in the environment.
#   5. A release (non-beta) Xcode selected: App Store Connect rejects beta SDKs.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

TEAM=5QC5886P5V
APP_ID=dev.halen.eq
PROFILE="$ROOT/Resources/HalenEQ_AppStore.provisionprofile"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist)"
BUILD="$(plutil -extract CFBundleVersion raw -o - Resources/Info.plist)"
OUT="$ROOT/dist/appstore"
STAGE="$(mktemp -d /tmp/halen-mas.XXXX)"
APP="$STAGE/Halen.app"
SANDBOX_TEST="${SANDBOX_TEST:-0}"

if [[ "$SANDBOX_TEST" == "1" ]]; then
    APP_SIGN="${APP_SIGN:-Apple Development}"
    ENTITLEMENTS="$STAGE/test.entitlements"
    # No profile locally, so only the entitlements that don't need one.
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.app-sandbox bool true" \
        -c "Add :com.apple.security.device.audio-input bool true" \
        -c "Add :com.apple.security.network.client bool true" "$ENTITLEMENTS" >/dev/null
else
    APP_SIGN="${APP_SIGN:-Apple Distribution: luka dadiani ($TEAM)}"
    PKG_SIGN="${PKG_SIGN:-3rd Party Mac Developer Installer: luka dadiani ($TEAM)}"
    ENTITLEMENTS="$ROOT/Resources/HalenEQ-AppStore.entitlements"
    missing=0
    security find-identity -v -p codesigning | grep -q "Apple Distribution" || { echo "✗ no 'Apple Distribution' certificate"; missing=1; }
    security find-identity -v | grep -qE "3rd Party Mac Developer Installer|Mac Installer Distribution" || { echo "✗ no 'Mac Installer Distribution' certificate"; missing=1; }
    [[ -f "$PROFILE" ]] || { echo "✗ missing $PROFILE"; missing=1; }
    xcodebuild -version | grep -qi beta && { echo "✗ beta Xcode selected — App Store Connect rejects beta SDKs"; missing=1; }
    xcode-select -p | grep -qi beta && { echo "✗ xcode-select points at a beta: $(xcode-select -p)"; missing=1; }
    (( missing )) && { echo "See docs/APP_STORE.md for the one-time setup."; exit 1; }
fi

echo "═══ Halen $VERSION ($BUILD) · Mac App Store ═══"
echo "→ build (no Sparkle)"
HALEN_APPSTORE=1 swift build -c release --product halen-eq --arch arm64 --build-path .build-appstore
BIN="$(HALEN_APPSTORE=1 swift build -c release --arch arm64 --build-path .build-appstore --show-bin-path)"
otool -L "$BIN/halen-eq" | grep -qi sparkle && { echo "✗ Sparkle is still linked"; exit 1; }

echo "→ assemble"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT"
cp "$BIN/halen-eq" "$APP/Contents/MacOS/HalenEQ"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/HalenMenubar*.png Resources/Doto.ttf Resources/Doto-OFL.txt \
   Resources/PrivacyInfo.xcprivacy Resources/Acknowledgements.txt "$APP/Contents/Resources/"
for b in "$BIN"/*.bundle(N); do ditto "$b" "$APP/Contents/Resources/$(basename "$b")"; done

P="$APP/Contents/Info.plist"
for k in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks SUScheduledCheckInterval SUEnableInstallerLauncherService; do
    plutil -remove "$k" "$P" 2>/dev/null || true
done
plutil -replace CFBundleName -string "Halen" "$P"
plutil -replace CFBundleDisplayName -string "Halen" "$P"
plutil -replace ITSAppUsesNonExemptEncryption -bool NO "$P"        # CryptoKit for local data only: exempt
plutil -replace CFBundleSupportedPlatforms -json '["MacOSX"]' "$P"
plutil -replace CFBundleInfoDictionaryVersion -string "6.0" "$P"
# Build metadata App Store Connect reads to know the SDK/toolchain.
SDKV="$(xcrun --sdk macosx --show-sdk-version)"; SDKB="$(xcrun --sdk macosx --show-sdk-build-version)"
plutil -replace DTSDKName -string "macosx$SDKV" "$P"
plutil -replace DTSDKBuild -string "$SDKB" "$P"
plutil -replace DTPlatformName -string macosx "$P"
plutil -replace DTPlatformVersion -string "$SDKV" "$P"
plutil -replace DTPlatformBuild -string "$SDKB" "$P"
plutil -replace DTXcode -string "$(xcodebuild -version | awk 'NR==1{split($2,v,"."); printf "%d%d%d", v[1], v[2], v[3]+0}')" "$P"
plutil -replace DTXcodeBuild -string "$(xcodebuild -version | awk 'NR==2{print $3}')" "$P"
plutil -replace DTCompiler -string com.apple.compilers.llvm.clang.1_0 "$P"
plutil -replace BuildMachineOSBuild -string "$(sw_vers -buildVersion)" "$P"
plutil -lint "$P" >/dev/null

[[ "$SANDBOX_TEST" == "1" ]] || cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
xattr -cr "$APP"

echo "→ sign ($APP_SIGN)"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$APP_SIGN" "$APP"
codesign --verify --strict --verbose=1 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q app-sandbox || { echo "✗ not sandboxed"; exit 1; }

if [[ "$SANDBOX_TEST" == "1" ]]; then
    rm -rf "$OUT/Halen.app"; ditto "$APP" "$OUT/Halen.app"; rm -rf "$STAGE"
    echo "✓ sandboxed test build: $OUT/Halen.app"
    exit 0
fi

echo "→ package"
PKG="$OUT/Halen-$VERSION-$BUILD.pkg"
productbuild --component "$APP" /Applications --sign "$PKG_SIGN" "$PKG"
pkgutil --check-signature "$PKG" | head -3
rm -rf "$STAGE"
echo "✓ $PKG"

if [[ "${UPLOAD:-0}" == "1" ]]; then
    : "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
    echo "→ validate + upload"
    xcrun altool --validate-app -f "$PKG" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
    xcrun altool --upload-app -f "$PKG" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
    echo "✓ uploaded — finish the submission in App Store Connect"
else
    echo "Upload: UPLOAD=1 ASC_KEY_ID=… ASC_ISSUER_ID=… ./scripts/appstore.sh   (or drag the .pkg into Transporter)"
fi
