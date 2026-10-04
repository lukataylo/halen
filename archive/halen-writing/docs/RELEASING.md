# Releasing Halen

How to take a `main` commit and produce a signed, notarized, drag-to-Install
DMG that opens cleanly on any Mac with no Gatekeeper warnings.

**Audience:** the next Claude session, and the maintainer when they come
back to this in six months. Assumes you're on the dev machine the cert
lives on (`luka.dadiani@me.com`, team `5QC5886P5V`).

---

## TL;DR — the three-step chain

Once the prerequisites in the next section are satisfied:

```bash
DIST=1 SIGN_IDENTITY=D049E93B91A2CF697C13CC77F8AE560AB6A96990 \
  ./scripts/build-app.sh

./scripts/notarize.sh

SIGN_IDENTITY=D049E93B91A2CF697C13CC77F8AE560AB6A96990 \
  ./scripts/package-dmg.sh
```

Output: `build/Halen-<version>.dmg`, ~4 MB, signed + notarized + stapled.
This is the file users download.

Each step is idempotent — rerunning any of them overwrites the prior
output. The two notarization submissions each take 1–5 minutes round-trip
to Apple; the rest is seconds.

---

## Prerequisites (do these once per machine)

### 1. Developer ID Application certificate

Already provisioned in this machine's login keychain. Verify with:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

You should see at least one identity for `luka dadiani (5QC5886P5V)`. If
there are *multiple* with the same name (which this machine has), the
bare name is ambiguous — that's why the commands above pass the SHA-1
hash `D049E93B91A2CF697C13CC77F8AE560AB6A96990` directly via
`SIGN_IDENTITY`. Pick any valid Developer ID Application hash from the
`security find-identity` output; they all sign equivalently.

If no Developer ID Application certificate is present:
- Open Xcode → Settings → Accounts → manage certificates
- Create a new "Developer ID Application" cert
- Or generate via developer.apple.com → Certificates → +
- Download into the login keychain (double-click the `.cer`)

### 2. App-specific password for `notarytool`

Apple's notary service refuses your regular Apple ID password and your
Xcode session token. You need a dedicated app-specific password.

1. https://appleid.apple.com → Sign-In and Security → App-Specific Passwords
2. Generate one labelled e.g. `notarytool halen`
3. Apple shows it once in `abcd-efgh-ijkl-mnop` format — copy it immediately

### 3. Store the notary credential in the keychain

`notarize.sh` and `package-dmg.sh` both authenticate against a keychain
profile named `halen-notary`. Create it once:

```bash
xcrun notarytool store-credentials "halen-notary" \
  --apple-id "luka.dadiani@me.com" \
  --team-id  "5QC5886P5V" \
  --password "<paste the app-specific password>"
```

Verify it's stored and Apple accepts it:

```bash
xcrun notarytool history --keychain-profile halen-notary
```

Should print a (possibly empty) submission table. If it errors with
"No Keychain password item found", the profile didn't store — rerun
the `store-credentials` command above.

---

## The three scripts in detail

### `scripts/build-app.sh` (with `DIST=1`)

What it does:

1. `swift build -c release` — produces an optimized `halen` binary
2. Detects iCloud-synced parents → stages bundle to `/tmp/halen-build/`
   (iCloud's fileprovider keeps re-stamping `com.apple.FinderInfo`,
   which codesign rejects)
3. Assembles `Halen.app` with `Contents/{MacOS,Resources,Frameworks}/`
4. Embeds `Vendor/llama.xcframework`'s framework into `Contents/Frameworks/`
5. Re-stamps the framework binary's `@rpath` to `@executable_path/../Frameworks`
6. Signs the framework with Hardened Runtime + secure timestamp
7. Signs the app with Hardened Runtime + secure timestamp +
   `Resources/Halen.entitlements` (mic, calendar)
8. `codesign --verify --strict` — must pass before proceeding

Always pass `SIGN_IDENTITY=<sha1>` on this machine — the bare cert name
matches three certificates and codesign refuses ambiguity.

Outputs:
- `/tmp/halen-build/Halen.app` (the real bundle, on iCloud-synced machines)
- `build/Halen.app` → symlink to the staging path

### `scripts/notarize.sh`

What it does:

1. Resolves `build/Halen.app` (follows the symlink if present — stapler
   refuses to operate through alias files)
2. Refuses to continue if the .app is signed with an Apple Development
   cert (Apple's notary only accepts Developer ID Application)
3. Refuses to continue if the `halen-notary` keychain profile is missing
4. `ditto -c -k --keepParent` zips the .app for upload
5. `xcrun notarytool submit … --wait` — uploads, waits for Apple's
   verdict (1–5 min typically). Exits non-zero on rejection.
6. `xcrun stapler staple` — embeds the notarization ticket inside the
   .app so it launches cleanly offline on the user's Mac
7. Verifies: `codesign --verify --deep --strict`, `spctl --assess`
   (must report `source=Notarized Developer ID`), `stapler validate`
8. Repackages the stapled .app as `build/Halen-<version>.zip`

### `scripts/package-dmg.sh`

What it does:

1. Refuses to package an unstapled .app (otherwise the DMG would clear
   Gatekeeper but the app inside would still warn after install)
2. Assembles a staging folder: `Halen.app` + `Applications` symlink
3. `hdiutil create -format UDZO` → compressed read-only DMG
4. Signs the DMG with the same Developer ID Application cert + secure
   timestamp (Hardened Runtime doesn't apply to DMGs — they have no
   Mach-Os of their own)
5. `xcrun notarytool submit` → wait → `stapler staple` the DMG itself
6. Verifies: `spctl --assess --type open`, `stapler validate`

The DMG must be notarized separately from the .app inside. Apple's
notary ticketing the .app makes the *app* trusted on launch, but
browsers attach a quarantine xattr to the downloaded `.dmg`; without
a stapled ticket on the DMG, the first double-click prompts
"Apple could not verify Halen.dmg" and the user has to right-click → Open.

---

## Self-test before sharing

Always do this once before sending the DMG to a real user. It
simulates the quarantine attribute a browser would attach:

```bash
xattr -w com.apple.quarantine "0083;$(date +%s);Safari;" build/Halen-0.1.0.dmg
open build/Halen-0.1.0.dmg
```

Expected sequence:
1. DMG mounts with no Gatekeeper prompt
2. Drag `Halen.app` to `Applications` (visible in the DMG window)
3. Eject the DMG, double-click `/Applications/Halen.app`
4. Halen menubar icon appears, onboarding window shows
5. Halen requests Accessibility + Input Monitoring (expected, unavoidable)

Any "Apple could not verify" or "App can't be opened" warning at any
step means a script didn't complete cleanly. Re-run the failing step;
if it persists, see the troubleshooting table below.

---

## Bumping the version

1. Edit `Resources/Info.plist`:
   - `CFBundleShortVersionString` (user-visible: `0.1.0` → `0.2.0`)
   - `CFBundleVersion` (build counter: `1` → `2`)
2. Re-run the three scripts. The DMG filename auto-picks the new version.
3. Commit Info.plist + tag: `git tag v0.2.0 && git push --tags`

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `codesign: ambiguous (matches X and Y)` | Multiple Developer ID certs with the same display name | Pass `SIGN_IDENTITY=<sha1>` from `security find-identity` |
| `Stapler is incapable of working with Alias files` | iCloud-staging put a symlink at `build/Halen.app` and stapler can't follow it | Already handled — both scripts now `readlink` first. If you see this, `git pull` for the symlink-follow fix |
| `notarytool: No Keychain password item found for profile: halen-notary` | Profile never stored, or was deleted | Re-run `xcrun notarytool store-credentials "halen-notary" …` from Prerequisites §3 |
| Notary returns `Invalid` | Almost always: missing Hardened Runtime, missing secure timestamp, or unsigned nested binary | `xcrun notarytool log <submission-id> --keychain-profile halen-notary` — Apple returns line-itemed reasons |
| `resource fork, Finder information, or similar detritus not allowed` | iCloud re-stamped `com.apple.FinderInfo` between `xattr -cr` and `codesign` | Already handled by staging to `/tmp/halen-build/`. If it recurs, `sudo killall securityd` to unwedge codesign, then retry |
| `errSecInternalComponent` from codesign | `securityd` is wedged | `sudo killall securityd` (it respawns), then retry |
| App opens but TCC permissions don't carry over after rebuild | Bundle was signed by a different identity than last time | Don't switch identities mid-development. If you must, run `scripts/reset-permissions.sh` so TCC re-prompts cleanly |

---

## What NOT to do

- **Don't put credentials in the repo.** The app-specific password
  belongs only in the macOS keychain via `notarytool store-credentials`.
  If you find yourself echoing one into a script, stop — it leaks into
  CI logs, shell history, and screen recordings.
- **Don't notarize an Apple Development build.** It's rejected by Apple
  after a 1–5 min round-trip. `notarize.sh` preflights this and fails
  fast; trust the preflight.
- **Don't ship without the self-test.** A signed-but-not-notarized DMG
  shows the same warning as an unsigned one. The only way to know
  Gatekeeper is happy is to clear quarantine and open it yourself.
- **Don't switch the cert used between `build-app.sh`, `notarize.sh`,
  and `package-dmg.sh`** in a single release. The DMG's signature
  authority and the .app's must match for downstream verification to be
  unambiguous.
- **Don't bundle the GGUF model unless asked.** `BUNDLE_MODEL=1` blows
  the .app from 4 MB to ~5 GB. `ModelDownloader` fetches it lazily on
  first use — that's the intended distribution model.

---

## Files this guide refers to

- `scripts/build-app.sh` — release build + sign
- `scripts/notarize.sh` — submit + staple .app
- `scripts/package-dmg.sh` — wrap + notarize + staple DMG
- `scripts/reset-permissions.sh` — clear TCC after identity changes
- `Resources/Info.plist` — version strings, usage descriptions
- `Resources/Halen.entitlements` — Hardened Runtime entitlements
- `Vendor/llama.xcframework/` — bundled inference framework
