#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d /private/tmp/halen-release-tests.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/llama.xcframework"
printf 'fixture' > "$FIXTURE/llama.xcframework/file"
file_sha="$(shasum -a 256 "$FIXTURE/llama.xcframework/file" | awk '{print $1}')"
tree_sha="$(printf 'F %s %s\n' "$file_sha" file | shasum -a 256 | awk '{print $1}')"
printf 'source=%s\ncommit=%s\ntree_sha256=%s\n' \
    'https://github.com/ggml-org/llama.cpp.git' \
    "$(tr -d '[:space:]' < "$ROOT/Vendor/LLAMA_CPP_COMMIT")" "$tree_sha" \
    > "$FIXTURE/provenance"
"$ROOT/scripts/verify-llama-framework.sh" \
    "$FIXTURE/llama.xcframework" "$FIXTURE/provenance" >/dev/null
sed 's#https://github.com/ggml-org/llama.cpp.git#https://example.invalid/llama.cpp.git#' \
    "$FIXTURE/provenance" > "$FIXTURE/wrong-source"
if "$ROOT/scripts/verify-llama-framework.sh" \
    "$FIXTURE/llama.xcframework" "$FIXTURE/wrong-source" >/dev/null 2>&1; then
    echo "error: provenance verifier accepted an unexpected source repository" >&2
    exit 1
fi
printf 'tampered' >> "$FIXTURE/llama.xcframework/file"
if "$ROOT/scripts/verify-llama-framework.sh" \
    "$FIXTURE/llama.xcframework" "$FIXTURE/provenance" >/dev/null 2>&1; then
    echo "error: provenance verifier accepted a modified tree" >&2
    exit 1
fi

cp /bin/ls "$FIXTURE/safe-mach-o"
"$ROOT/scripts/verify-macho-paths.sh" "$FIXTURE/safe-mach-o" >/dev/null
safe_index=0
for safe_rpath in /usr/lib/swift '@loader_path' '@executable_path/../Frameworks'; do
    safe_index=$((safe_index + 1))
    cp /bin/ls "$FIXTURE/safe-rpath-$safe_index"
    install_name_tool -add_rpath "$safe_rpath" "$FIXTURE/safe-rpath-$safe_index"
    "$ROOT/scripts/verify-macho-paths.sh" "$FIXTURE/safe-rpath-$safe_index" >/dev/null
done
install_name_tool -add_rpath /tmp/developer-build "$FIXTURE/safe-mach-o"
if "$ROOT/scripts/verify-macho-paths.sh" "$FIXTURE/safe-mach-o" >/dev/null 2>&1; then
    echo "error: Mach-O verifier accepted an absolute development rpath" >&2
    exit 1
fi

cp /bin/ls "$FIXTURE/traversal-mach-o"
install_name_tool -add_rpath '@loader_path/../x' \
    "$FIXTURE/traversal-mach-o"
if "$ROOT/scripts/verify-macho-paths.sh" "$FIXTURE/traversal-mach-o" >/dev/null 2>&1; then
    echo "error: Mach-O verifier accepted a traversal rpath" >&2
    exit 1
fi

echo "✓ release verifier regression tests passed"
