# Contributing to Halen

Halen is a small focused project and we're delighted to take help. This file
covers how to get a dev environment running, what kind of changes are most
useful, and the bar a pull request needs to clear.

## Get the dev loop working

```bash
git clone https://github.com/lukataylo/halen.git
cd halen
./scripts/run-dev.sh
```

`run-dev.sh` builds with `swift build`, assembles `build/Halen.app`, signs it
with your Apple Development cert (so macOS TCC permissions persist across
rebuilds), quits any running copy, launches the new one, and streams its log.

First-run permissions Halen will ask for: **Accessibility** and **Input
Monitoring**. Onboarding walks you through them. Without Accessibility, no
plugin can read or modify text — debugging plugin work that way is futile.

If `codesign` fails the first time with `errSecInternalComponent`, it usually
means `securityd` is wedged. `sudo killall securityd` and try again. If TCC
permissions don't carry across a rebuild, `scripts/reset-permissions.sh`
clears them so macOS re-prompts cleanly.

## Run the tests

```bash
swift test
```

117 tests under `Tests/HalenTests/` covering the inference router, event bus,
plugin manifest parsing, paragraph classifier, style rules, web-socket
bridge, model downloader, string-diff helpers, and the log redaction layer.

CI on every push and PR runs the same suite plus a release-config build on a
macOS 14 GitHub-hosted runner. See [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

## Accessibility

Halen runs inside macOS's Accessibility surface — the same one assistive
tech uses. The app itself has to be accessible too; that bar isn't
optional. Five rules every PR that adds or changes UI must clear:

1. **Every interactive control gets `.accessibilityLabel` and
   `.accessibilityHint`.** Buttons, toggles, text fields, pickers,
   sliders, color swatches. Decorative graphics get
   `.accessibilityHidden(true)`.
2. **Every animation guards Reduce Motion.** Read
   `AccessibilityPreferences.shared.reduceMotion` and skip the animation
   under it. Don't ship a spinner that ignores the user's vestibular needs.
3. **Every translucent surface uses `.adaptiveMaterial(...)`** instead
   of raw `.background(.regularMaterial)`. The modifier falls back to an
   opaque color under Reduce Transparency.
4. **Every text write via AX calls `AnnounceCenter.say(...)`.** A typo
   silently corrected via `kAXSelectedTextAttribute` is invisible to
   VoiceOver — the announcement is the bridge.
5. **Semantic fonts only.** `.body`, `.caption`, `.headline`, `.title3`.
   Never `.font(.system(size: N))` in new code — hardcoded sizes ignore
   "Larger Accessibility Sizes."

The pre-release smoke test (VoiceOver narrating onboarding, Switch
Control on a popover, keyboard-only Settings, Reduce Motion / Reduce
Transparency / Larger Text) is in
[`docs/wiki/accessibility.md`](docs/wiki/accessibility.md). Run it
before any release.

## What's worth working on

A few good first issues, in rough order of accessibility:

- **A built-in style rule** you wish was there by default. See
  [`Sources/Halen/Features/StyleGuide/StyleRulesStore.swift`](Sources/Halen/Features/StyleGuide/StyleRulesStore.swift)
  for the format. One PR can add multiple rules.
- **A typo seed entry** in
  [`Sources/Halen/Features/TypoStore.swift`'s `personalSeed`](Sources/Halen/Features/TypoStore.swift).
  Same idea — common misspellings everyone makes.
- **A plugin doc** under [`docs/wiki/plugins/`](docs/wiki/plugins/) if you
  notice something the existing docs miss.
- **A new out-of-process plugin** under [`plugins/`](plugins/). The two
  reference plugins (`burnout-copilot`, `meeting-prep`) are ~100 lines of
  Python each. Protocol docs in [`plugins/README.md`](plugins/README.md).
- **Bugs and rough edges** in the open issues — see the [Halen issue list](https://github.com/lukataylo/halen/issues).

For larger things, the [`ROADMAP.md`](ROADMAP.md) lists what we've explicitly
planned but not yet built. If you want to work on something there, open an
issue first so we can coordinate.

## Code style

Match the surrounding code. The repo is Swift 5.10 with strict concurrency
turned on, organised by feature folder. A few specifics:

- **Comments earn their place.** Halen's source carries deliberately heavy
  comments where they explain *why*, particularly for race conditions, AX
  edge cases, and macOS-specific gotchas. Don't comment away `let x = 1`; do
  comment "this dance is here because Carbon dispatches on a non-main thread."
- **`@MainActor`** on SwiftUI Views and anything that touches AX. CI will
  catch a missing annotation.
- **No force-unwraps in production paths.** Guard, return, log. The
  `HalenSupportDirectory.root` resolver exists specifically because every
  `.first!` we used to have was a crash waiting on someone's edge case.
- **`Log` for diagnostics, not `print`.** Lines under `/tmp/halen-trace.log`
  are how we debug; `print` is invisible in a release build.
- **Tests for non-trivial logic.** If you fix a bug, a regression test is
  the price of admission. If you add a feature with branches, cover the
  branches.

The CI workflow runs `swift test` and a release build — if either fails, the
PR can't merge.

## Pull request process

1. **Fork** the repo and create a topic branch (`git checkout -b fix/some-thing`).
2. **Make focused commits.** One concern per commit. Commit messages explain
   *why*, not just *what* — the diff already shows what.
3. **Test locally**: `swift test` plus a quick `./scripts/run-dev.sh` to make
   sure the app launches.
4. **Push and open a PR** against `main`. The PR template will walk you
   through the questions reviewers want answered.
5. **Wait for CI** to pass.
6. **Reviewer responses**: prefer pushing fixup commits over rewriting
   history during review. We squash on merge so the history stays tidy.

## Commit message convention

We don't enforce Conventional Commits, but we do prefer commit subjects that
read as imperatives ("Fix the typo dedup race", not "Fixed the typo dedup
race") and bodies that explain reasoning over restating the diff. A
representative example:

```
SentimentGuard: avoid re-firing the popover on the same paragraph

ParagraphClassifier was LRU-deduping, but the popover trigger ran
*after* the classifier returned — so two near-simultaneous text.pause
events for the same paragraph could both produce findings. Moved the
hash check to before classification so the dedup applies to the
expensive Gemma call too, not just the popover.

Fixes #123.
```

If you've co-authored with an AI assistant, add a `Co-Authored-By:` trailer.

## Plugin contributions

External plugins live under [`plugins/`](plugins/) and load through the
JSON-RPC host. The protocol contract is in [`plugins/README.md`](plugins/README.md);
the host bridge in
[`Sources/Halen/Plugins/External/HostBridge.swift`](Sources/Halen/Plugins/External/HostBridge.swift)
is the single source of truth for what RPC methods a plugin can call.

A plugin PR should include:

- A `halen-plugin.json` manifest with the right `events` and `permissions`.
- The implementation. Python is the path of least resistance — Halen ships
  `python3` on the system; no extra dependencies if you stay standard-library.
- A `README.md` in the plugin's folder. Match the shape of `burnout-copilot/`
  or `meeting-prep/`.

The Plugin Store curates plugins through
[`plugin-registry.json`](plugin-registry.json) at the repo root. We don't
auto-list third-party plugins from PRs yet; for v0.2.x the path is to land
your plugin under `plugins/` and we'll consider it for the curated catalog
when the registry surface matures.

## Asking questions

- **Bug or proposal**: open an [issue](https://github.com/lukataylo/halen/issues/new/choose).
- **Something else**: discussions aren't enabled yet; an issue with a `?` in
  the title is fine.

Thanks for considering helping.
