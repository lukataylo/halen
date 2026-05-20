# Halen Plugin Registry schema

`plugin-registry.json` is a **curated index** of installable external Halen
plugins. The in-app Plugin Store fetches it over HTTPS from:

```
https://raw.githubusercontent.com/lukataylo/halen/main/plugin-registry.json
```

It is *only* an index — the host never executes anything it lists. Each entry
points at a downloadable zip of a plugin directory. On install the Store
unpacks that zip, validates the embedded `halen-plugin.json` manifest with the
same `PluginManifest.validate(at:)` used for hand-installed plugins, and only
then registers the plugin. A bad manifest aborts the install.

## Top-level object

| Field             | Type     | Required | Notes |
|-------------------|----------|----------|-------|
| `_comment`        | string   | no       | Human note, ignored by the parser. |
| `schemaVersion`   | integer  | yes      | Registry schema version. Current: `1`. The host ignores registries whose `schemaVersion` it does not understand. |
| `halenApiVersion` | string   | no       | Plugin protocol version this registry targets. Informational. |
| `plugins`         | array    | yes      | List of plugin entries (see below). |

## Plugin entry

| Field         | Type    | Required | Notes |
|---------------|---------|----------|-------|
| `id`          | string  | yes      | Reverse-DNS identifier. MUST match the `id` in the plugin's `halen-plugin.json`. Used as the on-disk install directory name and the dedupe key against already-installed plugins. |
| `name`        | string  | yes      | Human-readable name shown in the Store row. |
| `summary`     | string  | yes      | One-line description (~70 chars for layout). |
| `author`      | string  | yes      | Plugin author / publisher. |
| `version`     | string  | yes      | Semver string of the offered build. |
| `icon`        | string  | no       | SF Symbol name for the Store row. Falls back to `puzzlepiece.extension`. |
| `category`    | string  | no       | One of `writing` / `voice` / `scheduling` / `focus` / `productivity`. Informational only — the dropdown no longer groups by category. |
| `sourceURL`   | string  | yes      | HTTPS URL of the plugin's source repo, shown as "View source". |
| `downloadURL` | string  | yes      | HTTPS URL of a **zip of the plugin directory**. The zip's top level (or a single top-level folder) must contain `halen-plugin.json`. |
| `isExample`   | boolean | no       | `true` marks an illustrative seed entry. The Store renders an "Example" tag and the entry is otherwise treated normally. |

## Download zip layout

The `downloadURL` zip must unpack to a plugin directory containing
`halen-plugin.json` plus the plugin executable and any local data files —
either at the archive root, or nested under exactly one top-level folder
(the Store flattens a single wrapping folder). The manifest `id` must equal
the registry entry `id`.

```
com.example.hello.zip
└── com.example.hello/        (optional single wrapping folder)
    ├── halen-plugin.json
    └── plugin.py
```

## Security

- HTTPS only. The Store rejects non-HTTPS `downloadURL`s.
- Nothing in the zip is executed during install — the Store only unpacks and
  validates. The plugin process is spawned later, by `PluginHost`, only if the
  user enables the plugin.
- Path-traversal entries in the zip are rejected during extraction.
- The manifest is validated with `PluginManifest.validate(at:)` before the
  plugin is registered; a failure deletes the unpacked directory.
