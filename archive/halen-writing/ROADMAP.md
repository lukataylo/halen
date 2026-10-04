# Halen roadmap

What we've planned but haven't shipped. Anything not on this list is
either in the [changelog](CHANGELOG.md) (shipped) or hasn't been
seriously considered yet (open a [feature request](https://github.com/lukataylo/halen/issues/new?template=feature_request.yml)).

Versions are best-effort targets — Halen is alpha, things slide. Items
inside a version are roughly ordered by what we'd do first.

If you want to take a swing at any of these, **open an issue first**
so we can coordinate. Several items are claimed and in-flight.

---

## v0.3.0 — *"Plugin cutover"*  (target: mid-2026)

Finish the out-of-process plugin migration started in v0.2.0. After
this release, the five default-off plugins live exclusively under
`plugins/`, and the host shrinks accordingly.

- **Auto-install bundled external plugins on first launch.** Today the
  `plugins/` directory ships in the repo but isn't copied into
  `~/Library/Application Support/Halen/Plugins/` automatically.
  Onboarding picks them up after the user opts in.
- **Remove in-process Style Guide, Email Reply, Autocomplete, Tone
  Profiles.** Once the external versions reach UX parity (tracked in
  [`docs/PLUGIN_EXTRACTION.md`](docs/PLUGIN_EXTRACTION.md)), the
  Swift sources move out of `Sources/Halen/Features/`.
- **`ui/ghostText` host RPC.** Unblocks Autocomplete extraction —
  external plugins can't currently draw inline suggestions.
- **`clipboard/set` + richer `ax/readSelection`.** Unblocks Email
  Reply extraction.
- **Plugin Store: install a third-party plugin from a URL.** Manifest
  validation, signature check, sandboxed test run, install into
  `~/Library/Application Support/Halen/Plugins/`.

## v0.4.0 — *"Selection-first"*  (target: late 2026)

The current trigger model — *act on the paragraph around the
caret* — works for writing flow but loses to a selection-first model
for revision passes. v0.4.0 unifies them.

- **Select → action palette.** Hold ⌃ over a selection to fan out
  all applicable plugin actions (rephrase, simplify, translate,
  expand, …) in one popover, ranked by what the user used last.
- **Per-app default action.** Same shortcut, different default per
  app — `⌃⌥R` in Mail.app rewrites for tone; in Xcode it shortens to
  a docstring.
- **Undo affordance for inline edits.** A pill on the caret-following
  overlay surfaces "↶ Undo Halen edit" for 4 s after any in-place
  rewrite. Backspace already works; this makes it discoverable.

## v0.5.0 — *"Knowledge"*  (target: 2027)

Halen has personal memory today only through your typo dictionary and
style rules. v0.5.0 turns *anything you've written* into context the
plugins can use, **without uploading any of it**.

- **Local vector index over your own writing.** A folder of opt-in
  sources — `~/Documents/Notes`, an Obsidian vault, exported email —
  embedded locally with a sentence-transformer model and stored in a
  SQLite-vss DB inside `~/Library/Application Support/Halen/`.
- **`memory/search` host RPC.** Plugins query the index by similarity
  and get back snippets + source paths. Ask Halen and Email Reply use
  it first.
- **"Cite from your notes" Email Reply mode.** When you draft a reply,
  Halen offers paragraphs from your own past writing that match the
  topic. You pick what to paste in; nothing is auto-inserted.
- **Forget button.** A clearly labeled "Clear all indexed text"
  switch in Settings → Privacy. No soft delete, no analytics on which
  sources were used.

## Backlog — *not yet scoped*

Things on the radar without a version yet. Order is not priority.

- **Windows / Linux ports.** Tracking macOS-first until v1.0 because
  the AX surface differs enough that splitting attention would slow
  every release. Likely a separate repo when it happens.
- **Browser extension parity.** The loopback WebSocket bridge exists;
  the extension surface is still 2 of the 10 plugins. Bringing
  Sentiment Guard and Style Guide into the browser is the next chunk.
- **iCloud-synced settings.** Opt-in mirror of plugin toggles, style
  rules, typo seeds, snippets. The blocker is conflict resolution on
  the typo dictionary, which mutates on every accepted edit.
- **Pluggable embedding models.** Let users swap the sentence-
  transformer used by the knowledge index. Will need a `model/embed`
  router tier.
- **Apple Intelligence "Writing Tools" handoff.** Detect when macOS
  is about to invoke Writing Tools and offer Halen as the route
  instead, so the user's chosen tone profile stays in effect.
- **Per-plugin telemetry — but only on-device.** Counters visible in
  Settings ("Typo Fixer caught 142 typos this week") with zero
  network exit. Useful for tuning; never leaves the Mac.

---

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
