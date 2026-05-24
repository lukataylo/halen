#!/usr/bin/env bash
set -euo pipefail

# One-time per machine.
#
# codesign needs to read the private key from the keychain on every signed
# binary. By default, macOS pops a "Allow codesign to access this key?"
# dialog the first time each tool calls it — and again every time you boot,
# because the key's *partition list* doesn't authorise codesign.
#
# build-app.sh signs 8 things per build (llama.framework, 4 nested Sparkle
# bundles, Sparkle itself, the .app). Without this setup, that's 8 prompts.
# After this setup: 0 prompts, forever.
#
# What this script does:
#   1. Find the signing identity (env SIGN_IDENTITY, or the saved
#      Developer ID Application cert if there's exactly one).
#   2. Update the key's partition list to allow apple-tool:, apple:,
#      codesign: — the set Apple's own xcodebuild uses.
#   3. macOS prompts ONCE for your keychain password, then never again.
#
# Re-run is safe — set-key-partition-list is idempotent.
#
# After running this once: ./scripts/build-app.sh runs without any prompts.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if [[ ! -f "$KEYCHAIN" ]]; then
    echo "error: login keychain not found at $KEYCHAIN" >&2
    echo "  override with KEYCHAIN=/path/to/keychain-db ./scripts/setup-signing-keychain.sh" >&2
    exit 1
fi

# Resolve the signing identity. Mirrors build-app.sh's default — dev cert
# unless DIST=1, or whatever the user passed via SIGN_IDENTITY. Accepts
# either the cert hash (40-hex SHA-1) or the human-readable name.
DIST="${DIST:-0}"
if [[ "$DIST" == "1" ]]; then
    IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
else
    IDENTITY="${SIGN_IDENTITY:-Apple Development: luka dadiani (75R33YUT6M)}"
fi

# `security find-identity` lists every codesigning identity with its SHA-1
# hash. If IDENTITY is already a 40-hex hash, use it directly. Otherwise
# substring-match against the human-readable name and pull the hash.
if [[ "$IDENTITY" =~ ^[0-9A-F]{40}$ ]]; then
    HASH="$IDENTITY"
else
    HASH="$(security find-identity -v -p codesigning "$KEYCHAIN" \
            | grep -F "$IDENTITY" \
            | head -1 \
            | awk '{print $2}' || true)"
    if [[ -z "$HASH" ]]; then
        echo "error: no codesigning identity matches \"$IDENTITY\" in $KEYCHAIN" >&2
        echo "  available:" >&2
        security find-identity -v -p codesigning "$KEYCHAIN" >&2 || true
        echo >&2
        echo "  fix: either fix the identity name above, or pass the hash explicitly:" >&2
        echo "       SIGN_IDENTITY=<40-hex-hash> ./scripts/setup-signing-keychain.sh" >&2
        exit 1
    fi
fi

echo "→ keychain: $KEYCHAIN"
echo "→ identity: $IDENTITY"
echo "→ hash:     $HASH"
echo
echo "macOS will prompt for your keychain password ONCE."
echo "After that, codesign runs silently in every future build."
echo

# The actual fix. -S takes a comma-separated list of allowed tools; the
# trio below mirrors Apple's xcodebuild default and is what Sparkle's own
# docs recommend for CI signing. -k '' opens the prompt; passing -k with
# a non-empty arg would skip the prompt and use that as the password.
#
# We let macOS prompt natively because (a) keeping the user's password
# out of any script is the obviously-right thing, and (b) the native
# Touch ID-or-password sheet is the same one the user sees once and
# remembers.
# Read the keychain password from the terminal so security never has to
# pop a GUI dialog mid-script. `read -s` hides the typed characters.
# This is the one and only password prompt — set-key-partition-list itself
# is silent once it has the password.
echo -n "Keychain password: "
read -rs KEYCHAIN_PASSWORD
echo
echo

security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$KEYCHAIN_PASSWORD" \
    "$KEYCHAIN" >/dev/null
# ^ stdout is the full list of every key in the keychain; not useful here.
# The password lives only in this process's memory; bash doesn't write
# `read` input to history.

# Drop a marker so build-app.sh's pre-flight knows setup has run for this
# identity. The marker name is scoped to the identity (different certs
# need separate set-key-partition-list calls), keyed by the same hash
# build-app.sh computes — so the two stay in sync.
MARKER_DIR="$HOME/.cache/halen"
MARKER="$MARKER_DIR/.signing-keychain-configured-$(printf '%s' "$IDENTITY" | shasum -a 256 | cut -c1-16)"
mkdir -p "$MARKER_DIR"
{
    echo "# Halen codesign keychain setup completed."
    echo "# Identity: $IDENTITY"
    echo "# Hash:     $HASH"
    echo "# Keychain: $KEYCHAIN"
    echo "# Date:     $(date)"
    echo "#"
    echo "# Delete this file and re-run scripts/setup-signing-keychain.sh"
    echo "# if codesign starts prompting again (e.g. after a keychain reset)."
} > "$MARKER"

echo
echo "✓ partition list updated — codesign will no longer prompt for this key."
echo "  marker written: $MARKER"
echo "  test it now: ./scripts/build-app.sh"
