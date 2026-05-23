# A+ sprint — resume point (2026-05-23)

Status: paused before the next `swift build` so the codesign password
prompt doesn't fire. Resume by re-running the build/test gate, then
merging Wave 2B and launching Wave 3.

## What's already landed in `main` (working tree, uncommitted)

### Wave 1 — merged, build green, 124 tests passing
- **Phase 0 quick wins** (SettingsView, FindingsPopover, PluginStoreModel,
  TypoFixer folder move).
- **Phase 1 hotkey conflict detection** — `HotkeyRegistrar` rejects
  duplicates, `HotkeyConflictRegistry` observable, yellow warning card
  before About in Settings. New tests in
  `Tests/HalenTests/HotkeyRegistrarTests.swift`.
- **Phase 2 perf** — `Support/Hashing.swift` rewritten to single-buffer
  hex encode; `ParagraphClassifierTests` gained P50/P99 latency
  assertions. Local: classify P50 ~0.13 ms, hash P50 ~6.5 µs.
- **Phase 4d menu equivalents** — `QuickActionsBridge` +
  `QuickActionRow` in `HalenCenterView`; `invokeAskHalen()` etc on
  AppCoordinator; `invokeFromMenu()` on the four plugins.
- **Phase 4e motion/transparency** — new
  `Sources/Halen/Support/AccessibilityPreferences.swift` (Observable
  singleton + `AdaptiveMaterial` view modifier). Applied to GlassCard,
  dropdown background, nav transitions, BusyLoader, voice pulse,
  TypingDots, OnboardingFlow surfaces.
- **Phase 4b VoiceOver announcements** — new
  `Sources/Halen/Support/AnnounceCenter.swift`; `CaretObserver.replaceRange`
  gained `describedAs:`; wired through TypoFixer, SnippetExpander,
  SentimentGuard, AskHalen, StyleGuide, Autocomplete, VoiceDictation.

### Wave 2 — three of four landed; one still in a worktree
- **2A SettingsView** (in main): 45 semantic-font replacements, 61 a11y
  modifiers, status-dot contrast bumped, decorative dots hidden from VO.
- **2C popovers/overlays/palette/onboarding** (in main):
  AskHalenPalette, FindingsPopover, OverlayController IndicatorPopover,
  OnboardingFlow, PluginStoreView, PluginPromptPresenter — Dynamic Type
  + a11y labels/hints + `@FocusState` focus-on-appear via the 80 ms
  `.task` hop (mirrors the existing AskHalenPalette pattern).
- **2D theme/voice/busy contrast** (in main): VoiceListening pill
  border `0.08 → 0.25`, BusyLoader ring stroke alpha `0.55 → 0.80`,
  doc comment on `Color.halenCobalt` warning that the 0.18 wash is
  decorative only.

### Wave 2B — **NOT yet in main** (lives in worktree)
- Worktree path: `.claude/worktrees/agent-a100d7c5ef583b8a6`
- Branch: `worktree-agent-a100d7c5ef583b8a6`
- Files modified (10):
  - `Sources/Halen/App/PluginDetailContainer.swift`
  - `Sources/Halen/Features/Autocomplete/AutocompleteDetailView.swift`
  - `Sources/Halen/Features/ClarityChecker/ClarityCheckerDetailView.swift`
  - `Sources/Halen/Features/EmailReply/EmailReplyDetailView.swift`
  - `Sources/Halen/Features/SentimentGuard/SentimentGuardDetailView.swift`
  - `Sources/Halen/Features/SnippetExpander/SnippetExpanderDetailView.swift`
  - `Sources/Halen/Features/StyleGuide/StyleGuideDetailView.swift`
  - `Sources/Halen/Features/ToneProfiles/ToneProfilesDetailView.swift`
  - `Sources/Halen/Features/TypoFixerDetailView.swift` *(see note)*
  - *(no AskHalenDetailView / VoiceDictationDetailView in repo)*
- Totals: 95 semantic-font replacements, 134 a11y modifiers, +194 lines.
- Build was clean in the worktree per the agent report.

⚠️ **Path drift**: the worktree branched *before* the Phase 0 TypoFixer
folder move, so it modified
`Sources/Halen/Features/TypoFixerDetailView.swift` (old root path),
while main has the file at
`Sources/Halen/Features/TypoFixer/TypoFixerDetailView.swift`.
Resolve by copying the worktree's edits to the new path, not by
re-creating the old path.

## Pickup steps (tomorrow)

1. `swift build` from repo root — confirm Wave 1 + 2A + 2C + 2D still
   compile clean. *(This will not prompt for password — the codesign
   step is in `scripts/build-app.sh`, not `swift build`.)*
2. `swift test` — should remain at 124 passing.
3. Merge Wave 2B from the worktree:
   - For each of the 9 detail views, diff worktree vs main
     (`git -C .claude/worktrees/agent-a100d7c5ef583b8a6 diff <path>`),
     apply by hand or via `git apply -3`.
   - For TypoFixerDetailView, take the worktree's diff and apply to the
     new `Features/TypoFixer/TypoFixerDetailView.swift` path.
   - Rebuild + test.
4. Clean up worktrees (after copying anything useful out):
   `git worktree remove --force .claude/worktrees/agent-XXXXX` for
   the four currently locked worktrees, then
   `git branch -D worktree-agent-XXXXX`.
5. Launch Wave 3 (8 plugin test files + docs/wiki/accessibility.md +
   CONTRIBUTING update) as a single agent — minor coordination needs.
6. Final gate: `swift build` + `swift test` + audit re-run.
7. **Then** the release pipeline if everything's green
   (`scripts/build-app.sh` → `scripts/notarize.sh` →
   `scripts/package-dmg.sh` → `scripts/publish-release.sh`) — this is
   where the codesign password lives, so save it for when you can
   sit through it.

## Locked worktrees (cleanup tomorrow)

All four are locked by the harness; `git worktree remove --force`
should still clear them once their parent agent processes exit:

- `.claude/worktrees/agent-a6a55c1d3de11204b` (perf, already copied out)
- `.claude/worktrees/agent-aedb74685b892be9c` (menu equiv, already copied)
- `.claude/worktrees/agent-ae7c957c5d60ecb6f` (motion, already copied)
- `.claude/worktrees/agent-a100d7c5ef583b8a6` (detail views, **NOT** copied yet — see step 3)

## Open issues to revisit

- The `nonisolated(unsafe)` warning on
  `Sources/Halen/Support/AccessibilityPreferences.swift:53` is pre-
  existing in the new file we just added. Worth tightening — probably
  by making the `NSWorkspace` observer a `@MainActor` closure.
- Wave 2D flagged that the plugin icon badge `ZStack` in
  `HalenCenterView.swift:446` and `PluginStoreView.swift:414` should be
  `.accessibilityHidden(true)` so VoiceOver doesn't read "icon" before
  the plugin name. Quick follow-up.
- Wave 3 will need to honor TypoFixer's new folder path when adding
  `TypoFixerTests.swift` (use `Features/TypoFixer/`, not
  `Features/`).

## Don't run

- `scripts/build-app.sh` — codesign password prompt.
- `scripts/notarize.sh` — Apple ID prompt.
- `scripts/package-dmg.sh` — okay alone but pointless without the
  signed app.
- `scripts/publish-release.sh` — pushes to GitHub Releases + updates
  appcast.xml; not yet.
