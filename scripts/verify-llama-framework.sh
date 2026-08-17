#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XCF="${1:-$ROOT/Vendor/llama.xcframework}"
MARKER="${2:-$ROOT/Vendor/llama.xcframework.provenance}"
PIN="$(tr -d '[:space:]' < "$ROOT/Vendor/LLAMA_CPP_COMMIT")"
EXPECTED_SOURCE="https://github.com/ggml-org/llama.cpp.git"

[[ "$PIN" =~ ^[0-9a-f]{40}$ ]] || { echo "error: invalid llama.cpp commit pin" >&2; exit 1; }
[[ -d "$XCF" ]] || { echo "error: missing $XCF" >&2; exit 1; }
[[ -f "$MARKER" ]] || { echo "error: missing provenance marker $MARKER" >&2; exit 1; }

tree_digest() {
    local tree="$1" entry rel digest
    while IFS= read -r entry; do
        rel="${entry#"$tree"/}"
        if [[ -L "$entry" ]]; then
            digest="$(printf '%s' "$(readlink "$entry")" | shasum -a 256 | awk '{print $1}')"
            printf 'L %s %s\n' "$digest" "$rel"
        else
            digest="$(shasum -a 256 "$entry" | awk '{print $1}')"
            printf 'F %s %s\n' "$digest" "$rel"
        fi
    done < <(find "$tree" \( -type f -o -type l \) -print | LC_ALL=C sort)
}

ACTUAL_DIGEST="$(tree_digest "$XCF" | shasum -a 256 | awk '{print $1}')"
MARKER_COMMIT="$(awk -F= '$1 == "commit" { print $2 }' "$MARKER")"
MARKER_DIGEST="$(awk -F= '$1 == "tree_sha256" { print $2 }' "$MARKER")"
MARKER_SOURCE="$(awk -F= '$1 == "source" { sub(/^source=/, ""); print }' "$MARKER")"

[[ "$MARKER_SOURCE" == "$EXPECTED_SOURCE" ]] || { echo "error: unexpected llama source marker" >&2; exit 1; }
[[ "$MARKER_COMMIT" == "$PIN" ]] || { echo "error: llama source marker does not match pinned commit" >&2; exit 1; }
[[ "$MARKER_DIGEST" == "$ACTUAL_DIGEST" ]] || { echo "error: llama.xcframework tree digest mismatch" >&2; exit 1; }
echo "✓ verified llama.xcframework provenance ($PIN, $ACTUAL_DIGEST)"
