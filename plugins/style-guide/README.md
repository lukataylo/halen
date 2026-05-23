# style-guide (out-of-process plugin)

A Python port of the in-process Personal Style Guide plugin. Mirrors the
matching semantics — case-insensitive substring with word boundaries for
literal rules, NSRegularExpression-compatible regex rules, at most one
match per `text.pause` paragraph — but delegates every privileged
operation to the Halen host over JSON-RPC.

## Status

**v0.2.0 ships the in-process Swift version as the default.** This
external plugin exists as a reference implementation and a preview of
how StyleGuide will ship in v0.3.0+, when the bundled-plugin
auto-install path lands and the in-process registration is removed.

You can already install this version manually:

```sh
cp -R /path/to/halen/plugins/style-guide \
      ~/Library/Application\ Support/Halen/Plugins/
```

The host's plugin discovery will pick it up on next launch. Because the
in-process StyleGuide registers first, its id (`com.halen.style-guide`)
takes precedence — so to test the external version you also need to
disable the in-process one, or pull this commit on a fresh install.

## What runs where

| Concern                                  | In-process Swift | External Python |
|------------------------------------------|------------------|-----------------|
| Rule storage (`rules.json`)              | Per-plugin dir   | `$HALEN_PLUGIN_DIR/rules.json` |
| Built-in defaults                        | `StyleRulesStore.builtins` | mirrored in `_BUILTINS` |
| Literal-vs-regex matching                | `wordRange` / NSRegularExpression | `_word_range` / Python `re` |
| Paragraph extraction at the caret        | `paragraphAroundCaret` | `_paragraph_around` |
| Hash-based dedup                         | `ParagraphClassifier` LRU | local `_seen_hashes` |
| AX read of the focused field             | `axReadString`  | `ax/readSelection` RPC |
| AX write to apply replacement            | `caretObserver.replaceRange` | `ax/replaceRange` RPC |
| UI for prompting the user                | `FindingsPopover` (native panel) | `ui/prompt` (system modal) |

The user-facing UX in the external version is a system modal instead of
a caret-anchored popover — that's a regression we accept for the first
extraction. A richer `ui/prompt` (or a new `ui/finding` method) would
restore parity later.

## Local dev

The plugin is single-file Python with no third-party dependencies. To
run it directly against a copy of Halen:

```sh
cd ~/Library/Application\ Support/Halen/Plugins/style-guide
# Halen launches this automatically on enable; ad-hoc testing via
# `python3 plugin.py` reads stdin from your terminal — only useful for
# verifying the script parses, not for actual matching.
python3 -c "import plugin; plugin.load_rules()"
```

## File layout

- `halen-plugin.json` — manifest (id, executable, args, events,
  permissions, icon, category).
- `plugin.py` — main script. Speaks NDJSON over stdio.
- `rules.json` — created on first run inside `$HALEN_PLUGIN_DIR`. The
  user's rules + the merged-in builtins.
