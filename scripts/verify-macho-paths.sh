#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:?usage: verify-macho-paths.sh <app-or-macho>}"
[[ -e "$TARGET" ]] || { echo "error: missing target $TARGET" >&2; exit 1; }
fail=0

verify_one() {
    local binary="$1" path
    while IFS= read -r path; do
        if [[ "/$path/" == *"/../"* ]]; then
            echo "error: traversal component in load path for $binary: $path" >&2
            fail=1
            continue
        fi
        case "$path" in
            @rpath/*|@loader_path/*|@executable_path/*|/System/Library/*|/usr/lib/*) ;;
            *) echo "error: unsafe development load path in $binary: $path" >&2; fail=1 ;;
        esac
    done < <(otool -L "$binary" |
        sed -nE 's/^[[:space:]]*([^[:space:]]+)[[:space:]]+\(compatibility version.*$/\1/p')

    while IFS= read -r path; do
        # SwiftPM emits the system Swift runtime paths below, and app bundles
        # conventionally reach Contents/Frameworks from Contents/MacOS with
        # this one exact parent hop. They are fixed, release-safe locations.
        case "$path" in
            /usr/lib/swift|@loader_path|@executable_path/../Frameworks) continue ;;
        esac
        if [[ "/$path/" == *"/../"* ]]; then
            echo "error: traversal component in LC_RPATH for $binary: $path" >&2
            fail=1
            continue
        fi
        case "$path" in
            @rpath/*|@loader_path/*|@executable_path/*) ;;
            *) echo "error: unsafe LC_RPATH in $binary: $path" >&2; fail=1 ;;
        esac
    done < <(otool -l "$binary" | awk '$1 == "cmd" { rpath=($2 == "LC_RPATH") } rpath && $1 == "path" { print $2; rpath=0 }')
}

while IFS= read -r candidate; do
    if file -b "$candidate" | grep -q 'Mach-O'; then
        verify_one "$candidate"
    fi
done < <(find "$TARGET" -type f -print 2>/dev/null || printf '%s\n' "$TARGET")

[[ "$fail" == 0 ]] || exit 1
echo "✓ Mach-O load paths are relocatable and release-safe: $TARGET"
