# Changelog

All notable changes to Halen are tracked here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning is [semver](https://semver.org/).

## [Unreleased]

### Reasoning Compactor → Claude Code
- **Reasoning Compactor now installs a Claude Code plugin.** Toggling Reasoning Compactor on installs `halen-local-compaction` into a local Claude Code marketplace and enables it in `~/.claude/settings.json`; toggling off removes it. The plugin compacts Claude Code's context **on-device** — its PreCompact hook routes the transcript through the running Halen app's local model over the loopback bridge (`127.0.0.1:50765`), so nothing is sent to the cloud for the summary, and its SessionStart hook re-injects that local summary on resume.
- Configure frequency, type (extractive/abstractive) and the major tradeoffs from inside Claude Code with `/halen-local-compaction:configure`. Degrades safely when Halen isn't running — it never blocks Claude Code's own `/compact`.

### Compaction model
- **New dedicated compaction model — Qwen3 4B Instruct 2507** (Apache-2.0, 256K context, non-thinking; ~2.5 GB). Added to the model manager with a new `.compaction` inference task kind: the router sends compaction work to it when it's downloaded, while writing/rewrite traffic stays on Gemma. It's an **opt-in download** from Settings → Inference (not auto-fetched); until then, compaction falls back to the built-in Gemma model.

## [0.3.0] — 2026-05-25

Six plugins, down from ten. Same features, simpler marketplace.

### Plugin lineup
- **Word Replacements** (new) replaces Typo Fixer + Personal Style Guide. One plugin, two tabs in its detail view — auto-typos and your preferred terms. Existing settings carry over.
- **Writing Coach** (new) replaces Sentiment Guard + Clarity Checker. Tone and clarity findings on the caret indicator from one classifier pass. Existing rules carry over.
- **Email Reply** is now part of Snippet Expander. Type `;reply` in any mail app or press ⌃⌥E. Default tone picker lives in Snippet Expander's detail view.
- **Tone Profiles** moved to Settings → App tone profiles. No longer a marketplace toggle.

### Hotkeys
- **Voice Dictation** rebinds to ⌃⌥Space. The previous ⌥⌘H collided with macOS's "Hide Others" shortcut, which intercepted the keystroke before Halen could see it.
- All global hotkeys now route through `NSEvent` monitors instead of Carbon's `RegisterEventHotKey`. On macOS 14+ the Carbon path stopped delivering events to handlers for chords that overlapped Cocoa menu shortcuts — silent registration but never fired.

### Voice Dictation
- Redesigned listening pill — 32×7 dot matrix with per-dot glow, a continuous scanner highlight on the centre row, and a deep-black capsule with a soft cobalt aura. Reduce Motion pins the scanner at mid-position.

### Privacy
- **Halen no longer appears in password fields.** Secure text fields (every login form, the macOS lock dialog, sudo prompts wrapped by a GUI helper) are skipped entirely at the AX subscription layer — no caret indicator, no text snapshots, no classifier runs.

### Reliability
- **Cancelled tone classifications no longer poison dedup.** A superseded paragraph hash is no longer added to the LRU, so the next classification of the same paragraph runs cleanly.
- **Caret indicator appears in Notes, Messages, and Electron apps.** The AX-focused-element notification doesn't fire reliably in WebKit-backed editors; a short retry burst (300 / 800 / 1600 ms after focus change) catches it.

### Settings
- **Inline underline preview removed.** The Halen mark's severity tint carries the same signal without the AX-frame guesswork that made the underline drift off-screen. Preserved on a feature branch for a future per-glyph implementation.

### Developer experience
- **No more 8x codesign password prompts per local build.** Run `scripts/setup-signing-keychain.sh` once; subsequent rebuilds are silent across reboots.

### Code quality
- Removed orphaned `invokeFromMenu` paths from Ask Halen, Voice Dictation, and Snippet Expander.
- Wiki and website copy updated to the new plugin lineup. README rewritten as customer-facing; architecture details live in `docs/wiki/`.

## [0.2.0] — 2026-05-23

The first signed, notarized release. Drag-to-Install with no Gatekeeper
warnings, ten built-in plugins, a first-run walkthrough, auto-updates
via Sparkle, and a Plugin Store window for future third-party plugins.

### Added
- **Notarized DMG distribution.** Downloaded from halen.dev or GitHub
  Releases, the DMG opens cleanly on a fresh Mac with no right-click →
  Open detour and no Settings → Security override. The .app inside is
  also notarized and stapled, so first launch from /Applications is
  warning-free.
- **Sparkle 2.x auto-updates.** Halen checks halen.dev/appcast.xml
  daily, verifies update payloads with EdDSA, and installs them in
  place. Settings → About gains a manual "Check for updates" button.
- **First-run setup walkthrough.** Three glassmorphic steps —
  Welcome, Choose plugins, Permissions — that runs on first launch and
  is re-runnable from Settings → "Run setup again."
- **Five new bundled plugins.** Personal Style Guide
  (banned-words/preferred-terms), Clarity Checker (passive voice +
  run-ons + vague pronouns + dangling modifiers), Tone Profiles
  (per-app formal/casual hints), Email Reply (⌃⌥E in Mail / Outlook /
  Spark / Airmail / Mimestream / Canary), Inline Autocomplete (ghost
  text, Tab to accept).
- **Inline-underline overlay.** Severity-tinted strip under flagged
  paragraphs, toggleable from Settings.
- **Plugin Store window.** Standalone window opened from the dropdown's
  header button, ready for third-party plugins via JSON-RPC over stdio.
- **Burnout Copilot and Meeting Prep are now out-of-process plugins.**
  They ship in this repo under `plugins/` and load via the same
  `ExternalPluginAdapter` path as any third-party plugin.
- **Streaming rewrite.** Sentiment Guard's rephrase action streams
  Gemma 4 output into the popover instead of waiting for the whole
  response.
- **Default-off plugin set.** Voice Dictation, Autocomplete, Style
  Guide, Email Reply, and Tone Profiles default to off on a fresh
  install; onboarding's Choose step flips them on if the user opts in.
- **Snippet Expander field-per-row form.** The add-snippet sheet's
  cramped two-column layout has been replaced with a field-per-row
  layout, validation hints, and explicit trigger length bounds.

### Changed
- **Dedicated classifier model.** Tone scans now route through Qwen
  2.5 0.5B (the `.classifier` tier) instead of Gemma 4. Sub-100 ms
  warm latency.
- **Plugin layout reorganised.** Each first-party plugin lives in its
  own subdirectory under `Sources/Halen/Features/` (e.g.
  `SentimentGuard/`, `StyleGuide/`).
- **Apple-style microcopy pass.** All user-facing copy — onboarding,
  Settings labels, popover headlines, plugin summaries — shortened
  and simplified.
- **Paragraph-classification settle 2.5 s → 1.0 s.** Faster popovers
  while typing.

### Fixed
- **iCloud-synced repos can codesign.** Build script stages to
  `/tmp/halen-build/` when the parent directory is iCloud-managed,
  defeating the `com.apple.FinderInfo` re-stamping that codesign
  refuses.
- **TCC permissions survive rebuilds.** The dev-build cert identity
  stays stable across rebuilds; resetting permissions has a dedicated
  helper script.
- **Force-unwraps on Application Support directory** replaced with a
  shared `HalenSupportDirectory.root` resolver that falls back to
  `NSTemporaryDirectory()`.
- **StyleGuide word-boundary correctness.** Banning "form" does not
  flag "format"; locked in by `Tests/HalenTests/StyleRulesStoreTests`.
- **Input-size guards.** AskHalen trims questions > 8 000 chars;
  SnippetExpander caps trigger length at 32 chars and value at 4 000;
  ParagraphClassifier skips paragraphs > 4 000 chars (almost always
  pasted code/logs).

### Removed
- **MLX backend moved off main.** mlx-swift can't compile its Metal
  shaders via `swift build`, so the MLX path lives on the
  `mlx-activation` branch until an xcodebuild pipeline lands. The
  llama.cpp Qwen 0.5B classifier already hits the sub-100 ms target,
  which was the original speed goal.

## [0.1.0-alpha] — 2026-05-16

First public download. Ad-hoc signed (no Developer ID yet), so
Gatekeeper blocks the first launch and the user has to right-click →
Open. Bundled seven first-party plugins: Ask Halen, Typo Fixer,
Sentiment Guard, Voice Dictation, Snippet Expander, Burnout Copilot,
Meeting Prep.

[Unreleased]: https://github.com/lukataylo/halen/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/lukataylo/halen/releases/tag/v0.2.0
[0.1.0-alpha]: https://github.com/lukataylo/halen/releases/tag/v0.1.0-alpha
