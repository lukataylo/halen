#!/usr/bin/env bash
#
# Fetches the large build inputs that are *not* tracked in git:
#   - assets/Models/gemma-4-E4B-it-IQ4_XS.gguf  (downloaded + checksum-verified)
#   - Vendor/llama.xcframework                  (rebuilt from the pinned tag)
#
# Only needed for `BUNDLE_MODEL=1` builds — the default slim build downloads
# the GGUF on first use via the in-app `ModelDownloader`. Run once on a fresh
# checkout before `BUNDLE_MODEL=1 ./scripts/build-app.sh`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ---------------------------------------------------------------------------
# 1. Bundled model — Gemma 4 E4B (IQ4_XS GGUF, ~4.72 GB)
#    Constants must match Sources/Halen/Inference/LlamaCpp/ModelDownloader.swift
#    Set SKIP_GGUF=1 when only the xcframework is needed (CI build/test, dev
#    flows that rely on the in-app ModelDownloader to fetch on first use).
# ---------------------------------------------------------------------------
GGUF_PATH="assets/Models/gemma-4-E4B-it-IQ4_XS.gguf"
GGUF_URL="https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/653803f092503c04a65164346f3208a36e707693/gemma-4-E4B-it-IQ4_XS.gguf"
GGUF_SHA="eb29c8519c4c07b880fb9cae7ff13ee2e30c5f38516268920ab85c04df6d52a2"

if [[ "${SKIP_GGUF:-0}" == "1" ]]; then
    echo "→ SKIP_GGUF=1 — skipping bundled model download"
elif [[ -f "$GGUF_PATH" ]] && shasum -a 256 "$GGUF_PATH" | grep -q "$GGUF_SHA"; then
    echo "✓ $GGUF_PATH (checksum OK)"
else
    echo "→ downloading $GGUF_PATH (~4.72 GB)"
    mkdir -p "$(dirname "$GGUF_PATH")"
    curl -L --fail -o "$GGUF_PATH.partial" "$GGUF_URL"
    actual="$(shasum -a 256 "$GGUF_PATH.partial" | awk '{print $1}')"
    if [[ "$actual" != "$GGUF_SHA" ]]; then
        rm -f "$GGUF_PATH.partial"
        echo "error: checksum mismatch (got $actual, want $GGUF_SHA)" >&2
        exit 1
    fi
    mv "$GGUF_PATH.partial" "$GGUF_PATH"
    echo "✓ $GGUF_PATH"
fi

# ---------------------------------------------------------------------------
# 2. llama.cpp xcframework — built from the immutable pinned commit
# ---------------------------------------------------------------------------
if [[ -d "Vendor/llama.xcframework" ]] && [[ "${REBUILD_LLAMA:-0}" != "1" ]] \
    && ./scripts/verify-llama-framework.sh; then
    echo "✓ Vendor/llama.xcframework (verified cache hit)"
else
    TAG="$(cat Vendor/LLAMA_CPP_VERSION)"
    COMMIT="$(tr -d '[:space:]' < Vendor/LLAMA_CPP_COMMIT)"
    echo "→ building Vendor/llama.xcframework from llama.cpp $TAG ($COMMIT)"
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    git init -q "$WORK/llama.cpp"
    (
        cd "$WORK/llama.cpp"
        git remote add origin https://github.com/ggml-org/llama.cpp.git
        git fetch --depth 1 origin "$COMMIT"
        git checkout -q --detach FETCH_HEAD
        [[ "$(git rev-parse HEAD)" == "$COMMIT" ]] || { echo "error: fetched unexpected llama.cpp commit" >&2; exit 1; }
        # macOS-only (arm64) trim of the upstream multi-platform script: keep its
        # options + assembly functions (lines 1-402), append just the macOS path.
        sed -n '1,402p' build-xcframework.sh > build-macos-only.sh
        cat >> build-macos-only.sh <<'INNER'

echo "Building for macOS (arm64 only)..."
cmake -B build-macos -G Xcode "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOS_MIN_OS_VERSION} \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
    -DLLAMA_OPENSSL=OFF -S .
cmake --build build-macos --config Release -- -quiet
setup_framework_structure "build-macos" ${MACOS_MIN_OS_VERSION} "macos"
combine_static_libraries "build-macos" "Release" "macos" "false"
rm -rf build-apple
xcrun xcodebuild -create-xcframework \
    -framework "$(pwd)/build-macos/framework/llama.framework" \
    -debug-symbols "$(pwd)/build-macos/dSYMs/llama.dSYM" \
    -output "$(pwd)/build-apple/llama.xcframework"
INNER
        bash build-macos-only.sh

        # combine_static_libraries hardcodes a universal build; we built arm64
        # objects only, so the x86_64 slice is a junk stub that breaks codesign.
        # Thin to arm64-only and correct the xcframework metadata.
        XCF="build-apple/llama.xcframework"
        FWBIN="$XCF/macos-arm64_x86_64/llama.framework/Versions/A/llama"
        lipo "$FWBIN" -thin arm64 -output "$FWBIN.thin" && mv "$FWBIN.thin" "$FWBIN"
        codesign --remove-signature "$FWBIN" 2>/dev/null || true
        mv "$XCF/macos-arm64_x86_64" "$XCF/macos-arm64"
        plutil -replace AvailableLibraries.0.LibraryIdentifier -string "macos-arm64" "$XCF/Info.plist"
        plutil -remove AvailableLibraries.0.SupportedArchitectures.1 "$XCF/Info.plist"
    )
    rm -rf Vendor/llama.xcframework Vendor/llama.xcframework.provenance
    cp -R "$WORK/llama.cpp/build-apple/llama.xcframework" Vendor/llama.xcframework
    digest="$({
        while IFS= read -r entry; do
            rel="${entry#Vendor/llama.xcframework/}"
            if [[ -L "$entry" ]]; then
                hash="$(printf '%s' "$(readlink "$entry")" | shasum -a 256 | awk '{print $1}')"
                printf 'L %s %s\n' "$hash" "$rel"
            else
                hash="$(shasum -a 256 "$entry" | awk '{print $1}')"
                printf 'F %s %s\n' "$hash" "$rel"
            fi
        done < <(find Vendor/llama.xcframework \( -type f -o -type l \) -print | LC_ALL=C sort)
    } | shasum -a 256 | awk '{print $1}')"
    printf 'source=%s\ncommit=%s\ntree_sha256=%s\n' \
        'https://github.com/ggml-org/llama.cpp.git' "$COMMIT" "$digest" \
        > Vendor/llama.xcframework.provenance
    ./scripts/verify-llama-framework.sh
    rm -rf "$WORK"
    trap - EXIT
    echo "✓ Vendor/llama.xcframework (arm64)"
fi

echo "✓ assets ready"
