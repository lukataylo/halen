# Halen roadmap

What we've planned but haven't shipped. Anything not on this list is
either in the [changelog](CHANGELOG.md) (shipped) or hasn't been
seriously considered yet (open a [feature request](https://github.com/lukataylo/halen/issues/new?template=feature_request.yml)).

Versions are best-effort targets — Halen is alpha, things slide. Items
inside a version are roughly ordered by what we'd do first.

If you want to take a swing at any of these, **open an issue first**
so we can coordinate.

---

## Shipped: v0.4.0 — *"The platform pivot"*

Halen became a plugin platform: HalenPluginAPI, capability enforcement,
one permissions screen, the priority inference queue, Mother first-party,
and Notch Boss (the absorbed NotchBar app). See the
[changelog](CHANGELOG.md) for the full list.

## Next — *"Stabilize API 0.1"*

Boring on purpose. The plugin API proves itself by not changing.

- **Fix what the pivot shook loose.** A restructure this size will have
  rough edges; issues labelled `pivot` get priority.
- **Exercise the example plugin path end to end** on a clean machine and
  fold what's learned back into PLUGINS.md.
- **Selection-first actions.** Hold ⌃ over a selection to fan out
  applicable plugin actions in one popover — the one pre-pivot feature
  idea that survives on its merits.

## Only if someone else writes a plugin

These get built the day a stranger ships a plugin that needs them, and
not before:

- **Plugin sandboxing.** sandbox-exec profiles derived from the manifest's
  capability list, so an external plugin is *mechanically* limited to what
  it declared instead of RPC-gated.
- **Streaming inference over the external RPC** (first-party plugins
  already stream through the Swift API).
- **Install-from-URL with signature verification** — the seed of a store,
  which is exactly why it waits for demand.

## Not on the roadmap, and probably never

A short list to save everyone time. If you disagree with any of
these, open an issue — we're persuadable, but the default is no.

- **A cloud sync of your text.** Not even opt-in. Halen's whole
  promise is "nothing leaves your Mac"; the moment we add a cloud
  store, that sentence stops being true.
- **An online account.** No login, no email at install, no "sign in
  with Google." If you didn't have to enter an email to install
  Halen, you shouldn't have to enter one to keep using it.
- **Telemetry, error reporting, crash uploads.** We rely on Apple's
  crash reporter and on issue reports. Anything more is a privacy
  regression.
- **Closed-source plugins shipped with the .app.** External plugins
  can be closed-source — but anything that ships *inside* `Halen.app`
  is in this repository.
- **A subscription.** Halen is MIT, the .app is free, and we've made
  no commitment about that changing — but if it ever does, the
  existing version stays free forever and we'll say so in advance.

---

If you want something on this list, the path is:

1. Check [open issues](https://github.com/lukataylo/halen/issues) —
   it might already be tracked.
2. Open a [feature request](https://github.com/lukataylo/halen/issues/new?template=feature_request.yml).
3. We'll either label it `roadmap` and add it here, or explain why
   not.
