#!/usr/bin/env bash
#
# Reset Halen's macOS privacy permissions so a fresh or re-signed build can
# request them cleanly.
#
# WHY THIS IS NEEDED
# macOS TCC keys a permission grant to the app's *code signature*. When the
# signature changes — an ad-hoc build, a failed `codesign`, switching signing
# identity — TCC's existing grant still points at the old signature. The new
# build then can't use the permission, and System Settings won't let you
# toggle the orphaned entry off and on again. `tccutil reset` clears the
# grant entirely; the app re-prompts from scratch on next use.
#
# Run this when Accessibility / Microphone / Calendar / etc. are stuck. It
# does NOT need sudo (it resets the current user's own TCC).
#
# The real fix for *recurring* churn is a stable signature: build with the
# Apple Development cert (scripts/build-app.sh default) and keep `codesign`
# healthy — if `codesign` is failing with errSecInternalComponent, reboot to
# clear a wedged `securityd`.
set -uo pipefail

BUNDLE="com.dadiani.halen"

echo "→ quitting Halen (TCC reset is cleanest with the app not running)…"
osascript -e 'quit app "Halen"' 2>/dev/null || true
killall halen 2>/dev/null || true
sleep 1

# Every TCC service Halen touches. `reset All <bundle>` clears them in one
# call; the explicit list is the fallback (older macOS) and documents the set:
#   Accessibility      — caret tracking + inline text writes (required)
#   Microphone         — Voice Dictation audio capture
#   SpeechRecognition  — on-device dictation transcription
#   Calendar           — Meeting Prep / Burnout Copilot plugins
#   ListenEvent        — Input Monitoring, for the ⌃H / ⌃⌥R hotkeys
echo "→ resetting TCC permissions for $BUNDLE"
if tccutil reset All "$BUNDLE" 2>/dev/null; then
    echo "   reset All services"
else
    for service in Accessibility Microphone SpeechRecognition Calendar ListenEvent; do
        if tccutil reset "$service" "$BUNDLE" 2>/dev/null; then
            echo "   reset $service"
        fi
    done
fi

echo
echo "✓ Done. Relaunch Halen — it re-prompts for each permission as it needs"
echo "  it: Accessibility at launch, Microphone + Speech on first dictation,"
echo "  Calendar + Input Monitoring when the relevant plugin / hotkey runs."
echo
echo "Note: notifications are not TCC-managed and can't be reset here. If"
echo "Halen's notifications misbehave, remove + re-add Halen under System"
echo "Settings → Notifications — it re-prompts once the app's signature is"
echo "stable across builds."
