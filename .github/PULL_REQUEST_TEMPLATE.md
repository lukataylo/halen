<!--
Thanks for the PR. The questions below are the ones reviewers will ask;
answering them up-front shortens the round trip. Delete sections that
don't apply.
-->

## What this changes

<!-- One paragraph. What did you actually change, and why? The diff
shows what; this should explain why. -->

## Why

<!-- The problem this solves. Link the issue if there is one (`Fixes #123`,
`Refs #456`). If there isn't an issue, a short user story works. -->

## How to verify

<!-- The shortest path a reviewer can take to see this working.
Hotkey + app + text snippet beats "trust the unit test." For new
plugins, include the toggle in Settings → Plugins. -->

```
1. ./scripts/run-dev.sh
2. …
3. Expected: …
```

## Scope

- [ ] Host (event bus, router, AX, settings, onboarding)
- [ ] Existing built-in plugin (which: …)
- [ ] New built-in plugin
- [ ] External plugin under `plugins/`
- [ ] Inference backend / model routing
- [ ] Build / packaging / CI
- [ ] Docs only
- [ ] Web (`index.html`, `privacy.html`, `changelog.html`)

## Checks

- [ ] `swift test` passes locally (117 tests + anything I added).
- [ ] `./scripts/run-dev.sh` launches the app and the change works end-to-end.
- [ ] New non-trivial logic has a test. Bug fixes have a regression test.
- [ ] No new force-unwraps in production paths. No `print` — used `Log`.
- [ ] User-facing copy stays in Halen's voice (short, lowercase-leaning, no marketing).
- [ ] `CHANGELOG.md` updated under `## [Unreleased]` if user-visible.
- [ ] Docs/wiki updated if behavior changed.

## Privacy

<!-- Halen is local-first. If this PR touches the network, model
loading, telemetry, file system, or anything that could leak text,
spell out exactly what crosses the boundary. "No new network traffic"
is a fine answer. -->

## Screenshots / recordings

<!-- For UI-visible changes, a screenshot or a short clip is worth
the 30 seconds. Drag the file straight into this textarea. -->

## Notes for the reviewer

<!-- Anything that isn't obvious from the diff: race conditions you
considered, alternatives you tried and rejected, follow-up work you'd
like to defer to its own PR. -->
