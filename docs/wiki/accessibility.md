# Accessibility

Halen lives inside the macOS Accessibility surface — it watches the caret
via AX, writes text back via AX, runs hotkeys via Carbon, and renders its
UI through SwiftUI on top of NSHostingView panels. That puts us in an odd
position: the API we depend on is the same one assistive tech uses to
help users with disabilities, so the app *itself* has to be a polite
citizen of that surface. A typo silently fixed via `kAXSelectedTextAttribute`
is invisible to VoiceOver unless we announce it. A glass popover that
ignores Reduce Transparency is a wall of muddy text to someone with low
vision. Hotkey-only entry points are a closed door to anyone who can't
press chord combinations.

This page documents what we ship, the bar every contributor PR has to
clear, and the manual smoke test we run before each release.

## What we ship

### `AnnounceCenter.say(_:priority:)`

Posts an `NSAccessibility` announcement so VoiceOver speaks an inline
edit out loud. Used by TypoFixer, SnippetExpander, SentimentGuard,
AskHalen, StyleGuide, Autocomplete, and VoiceDictation — every
plugin that writes text via AX. New plugins that write text MUST call
this helper or the change is silent to assistive tech.

```swift
// After a successful inline rewrite:
AnnounceCenter.say("Fixed 'teh' to 'the'")

// For high-priority messages that should cut through current speech:
AnnounceCenter.say("Answer inserted at cursor", priority: .high)
```

### `AccessibilityPreferences.shared`

`@Observable` singleton wrapping macOS's accessibility prefs. Two
properties matter:

- `reduceMotion` — true when System Settings → Accessibility → Display →
  Reduce Motion is on. Updates live via
  `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`.
- `reduceTransparency` — true when Reduce Transparency is on, same
  notification.

Reading either from a SwiftUI view does the right thing — the view
re-renders when the preference flips. No restart required.

```swift
@State private var prefs = AccessibilityPreferences.shared

// In a View body:
if prefs.reduceMotion {
    // … no animation
} else {
    .animation(.spring, value: …)
}
```

### `.adaptiveMaterial(_:fallback:)`

View modifier that swaps a translucent material for an opaque color
under Reduce Transparency. Drop-in replacement for `.background(.regularMaterial)`:

```swift
.adaptiveMaterial(.regularMaterial)                      // default fallback
.adaptiveMaterial(.thinMaterial, fallback: .secondary)   // explicit fallback
```

Used by `GlassCard`, the menubar dropdown, the onboarding window, and
every other glass surface. New code SHOULD use this modifier instead of
`.background(.regularMaterial)` directly.

### Quick Actions in the menubar dropdown

The four global-hotkey features (Ask Halen ⌃H, Rephrase selection
⌃⌥R, Reply to email ⌃⌥E, Start dictation ⌥⌘H) all have a
keyboard-reachable button in the menubar dropdown. The chord is shown
as a hint, but the button works regardless of whether the user can
press it. Switch Control, RSI, and non-US-layout users land here.

Every new hotkey-driven feature MUST add a Quick Actions row.

### Semantic fonts everywhere

The codebase uses `.body`, `.caption`, `.headline`, `.title3` — not
`.font(.system(size: 11))`. Hardcoded sizes ignore the user's
"Larger Accessibility Sizes" preference; semantic fonts scale.

The mapping we landed on during the A+ sprint:

| Old hardcoded | Semantic equivalent |
|--------------:|---------------------|
| `size: 10`    | `.caption2`         |
| `size: 11`    | `.caption`          |
| `size: 12`    | `.callout`          |
| `size: 13`    | `.body`             |
| `size: 14`    | `.headline`         |
| `size: 16+`   | `.title3` / `.title2` |

When weight matters, follow with `.fontWeight(.medium)` etc — that
preserves Dynamic Type scaling.

## The contributor bar

Every PR that adds or changes UI has to clear these five rules. They're
also documented in `CONTRIBUTING.md`.

1. **Every interactive control gets `.accessibilityLabel` and
   `.accessibilityHint`.** Buttons, toggles, text fields, pickers,
   sliders, segmented controls, color swatches — everything. Decorative
   elements (status dots, separator icons, badge backgrounds) get
   `.accessibilityHidden(true)`.
2. **Every animation guards Reduce Motion.** Read
   `AccessibilityPreferences.shared.reduceMotion`; under it, skip the
   animation or swap to a plain opacity fade.
3. **Every translucent surface uses `.adaptiveMaterial(...)`.** Plain
   `.background(.regularMaterial)` is forbidden in new code.
4. **Every text write via AX calls `AnnounceCenter.say(...)`.** A typo
   silently fixed is a typo VoiceOver users never hear.
5. **Semantic fonts only.** `.font(.system(size: N))` is forbidden in
   new code. Use `.body` / `.caption` / `.headline` etc.

CI doesn't enforce these yet — review does. A reviewer asking "where's
the announcement?" or "where's the reduce-motion guard?" is a normal,
expected note on UI PRs.

## Contrast budget

We aim at WCAG AA: **4.5:1** for body text, **3:1** for icons and large
text (≥18pt). The colors that needed adjustment during the sprint and
are now locked in:

| Site | Before | After | Why |
|------|-------:|------:|-----|
| Settings `.ok` status dot | RGB (0.20, 0.78, 0.35) | (0.12, 0.55, 0.22) | Light-mode contrast failed at 0.78 green |
| Settings `.warning` dot | `Color.orange` | RGB (0.78, 0.42, 0.06) | Same |
| Voice listening pill border | `white.opacity(0.08)` | `0.25` | Border was nearly invisible |
| Busy loader ring stroke | `cobalt.alpha(0.55)` | `0.80` | Marginal on the rendered material blend |

The cobalt brand at 18% opacity (`pluginCategoryTint` washes, plugin
icon badges) is decorative-only — never put body text directly on it.
The icon drawn on top at full saturation clears the 3:1 non-text bar.

## Smoke test — before each release

Walk this end-to-end with VoiceOver and Switch Control before any
release. Failures here are release blockers.

1. **Onboarding with VoiceOver narrating.** Open onboarding from
   a fresh install. VoiceOver should read each step's headline, body,
   and call-to-action. The "Back" / "Continue" / "Skip" buttons should
   each announce their purpose.
2. **Keyboard-only Settings.** Cmd-Tab to Halen's menubar; open the
   dropdown. Tab through Quick Actions, plugin rows, the footer. Open
   Settings; Tab through every card. Toggle a plugin, change Ollama
   URL, hit Save. **Mouse unplugged for this whole step.**
3. **Inline edit announcement.** Open TextEdit. Turn VoiceOver on. Type
   `teh quick brown fox `. Listen for "Fixed 'teh' to 'the'." If
   silent, TypoFixer's announcement path regressed.
4. **Switch Control popover.** Turn Switch Control on, set auto-scan.
   Trigger Sentiment Guard with a hostile sentence. The popover
   should auto-focus the primary action ("Rephrase") — auto-scan
   should reach the buttons without manual intervention.
5. **Menu-equivalent reach.** With hotkeys *disabled* in Settings, open
   the menubar dropdown and run Ask Halen via the Quick Action.
   Listen for "Thinking" then "Answer inserted at cursor." Same for
   Rephrase selection, Reply to email, Start dictation.
6. **Reduce Motion.** System Settings → Accessibility → Display →
   Reduce Motion on. Open the dropdown, navigate to Settings — the
   slide-in transition should be a plain crossfade. Trigger any
   inference — the busy spinner should be a still cobalt dot.
7. **Reduce Transparency.** Same panel, Reduce Transparency on. The
   dropdown background, onboarding window, every `GlassCard` should
   render opaque (no frosted glass). The actual content stays legible.
8. **Larger Accessibility Sizes.** System Settings → Display → Larger
   Text on, slider to maximum. Open Settings — every label scales
   proportionally. No clipped frames, no overlapping rows.
9. **Contrast spot check.** Open Settings in light mode. The `.ok`
   green status dot next to "Granted" should be clearly visible
   against the GlassCard background — not a pastel blur.

## What we don't claim

- **No full keyboard-driven onboarding yet.** First-launch onboarding
  uses a windowed NSPanel; Switch Control auto-scan reaches every
  control, but a Tab-only path through the three steps still skips
  the rendered illustrations. v0.3 milestone.
- **No high-contrast color scheme override.** Halen follows the
  system's dark/light mode. A separate high-contrast scheme (forced
  pure black/white with no transparency) is roadmap, not shipped.
- **No screen-magnification testing.** We don't currently smoke-test
  with Zoom on. If you hit a layout bug at high zoom, please file
  it — we'll fold it into the smoke checklist.
