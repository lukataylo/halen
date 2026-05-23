# Changelog

All notable changes to Halen are tracked here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning is [semver](https://semver.org/).

## [Unreleased]

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
