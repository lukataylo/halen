# Halen on the Mac App Store

Everything that can be prepared in the repo is done. What's left needs your
Apple account (certificates, the App Store Connect record, the upload).

**Verified on this Mac (sandboxed probe, 4 Oct 2026):** call detection
(Core Audio process list) and the far-end level meter (Core Audio process tap)
both work inside the App Sandbox. The App Store build is the full app, not a
reduced one.

## What's already in place

| | |
|---|---|
| Build variant | `HALEN_APPSTORE=1` drops Sparkle entirely and defines `APPSTORE` (no updater UI) |
| Sandbox entitlements | `eq/Resources/HalenEQ-AppStore.entitlements`: sandbox, microphone, network client (one-time voice model download), app id + keychain group |
| Keychain | App Store build uses the data-protection keychain (needs the profile's app id) |
| Privacy manifest | `eq/Resources/PrivacyInfo.xcprivacy`: no tracking, no data collected; UserDefaults CA92.1, boot time 35F9.1, file timestamp C617.1 |
| Info.plist | script strips the `SU*` keys, sets `ITSAppUsesNonExemptEncryption = NO`, adds DT* SDK keys |
| First launch | Welcome window (reviewers no longer see "nothing"), mic permission asked there, **auto-listen is opt-in** |
| Icon | Full `.icns` (16 → 1024 px) |
| Screenshots | `docs/app-store/*.png`, 2880×1800 |
| Script | `eq/scripts/appstore.sh` builds, signs, packages, optionally uploads |

## Your one-time setup (about 20 minutes)

1. **Release Xcode.** This Mac only has `Xcode-beta`. App Store Connect rejects
   apps built with a beta SDK. Install Xcode 27 from the App Store, then
   `sudo xcode-select -s /Applications/Xcode.app`.
2. **Certificates** (developer.apple.com › Certificates › +):
   *Apple Distribution* and *Mac Installer Distribution*. Download both into
   the login keychain.
3. **App ID**: Identifiers › + › App IDs › `dev.halen.eq` (no extra capabilities needed).
4. **Provisioning profile**: Profiles › + › *Mac App Store Connect* › `dev.halen.eq`
   › Apple Distribution cert. Save it as
   `eq/Resources/HalenEQ_AppStore.provisionprofile` (git-ignored).
5. **App Store Connect › Apps › +**: macOS, name (see below), bundle id
   `dev.halen.eq`, SKU `halen-mac`.
6. *(Optional, for scripted upload)* App Store Connect › Users and Access ›
   Integrations › API key with *App Manager*. Put `AuthKey_<ID>.p8` in
   `~/.appstoreconnect/private_keys/`.

Then:

```bash
cd eq
./scripts/appstore.sh                                   # → dist/appstore/Halen-1.0.0-1.pkg
UPLOAD=1 ASC_KEY_ID=… ASC_ISSUER_ID=… ./scripts/appstore.sh   # or drag the .pkg into Transporter
```

Bump `CFBundleVersion` in `eq/Resources/Info.plist` for every upload.

## Open question before submitting

**Voice-check model licence.** The voice check uses FluidAudio's
`pyannote_segmentation` + `wespeaker_v2` Core ML models, downloaded at first
use from Hugging Face. FluidAudio's NOTICE lists these two as *legacy* files
whose licence "must be evaluated separately" (their newer Community-1 models
are CC-BY-4.0). The originals are believed to be pyannote segmentation (MIT)
and WeSpeaker ResNet (CC-BY-4.0), which would be fine with attribution
(`eq/Resources/Acknowledgements.txt`), but confirm before a commercial
listing, or switch to the Community-1 models.

## Listing

**Name:** Halen: Call Coach
**Subtitle:** One tip after every call
**Category:** Productivity (secondary: Business)
**Price:** Free
**Age rating:** 4+

**Promotional text**
One tip after every call. Halen hears only your side, runs entirely on your Mac, and never saves audio.

**Description**
Halen sits in your menu bar and listens to your side of your calls. When the call ends you get three scores and one thing to try next time.

PRESENCE: do you leave room for other people? Talk share, interruptions, long monologues.
CLARITY: can people follow you? Pace, ums and uhs, how much your voice moves.
COMPOSURE: do you stay steady when it gets tense? Measured against your own calm voice.

Rate each call with one drag. After six rated calls, Halen shows which habits line up with the calls you felt good about.

Private by design:
• A 30-second voice check teaches Halen your voice, so it ignores everyone else.
• The other side of the call is never recorded. Halen only measures how loud they are, to know when they're talking.
• Audio is never saved. Sound becomes numbers as it comes in, then it's gone.
• Saving your own words is off by default.
• No account. Nothing is uploaded.

Works with Zoom, Microsoft Teams, FaceTime, Slack, Webex, Discord, WhatsApp, and browser calls like Google Meet.

Requires a Mac with Apple silicon. Takeaways are written on-device with Apple Intelligence when it's available.

**Keywords** (100 chars)
`speaking,meeting,coach,zoom,teams,communication,presentation,feedback,voice,talk,listening,interview`

**Support URL:** https://github.com/lukataylo/halen/issues
**Marketing URL:** https://halen.dev
**Privacy policy URL:** https://halen.dev/privacy.html

## App Privacy (nutrition label)

**Data Not Collected.** Nothing leaves the device: no analytics, no account,
no server. (The voice-model download is a static file fetch with no user data.)

## App Review notes

> Halen is a menu bar app. On first launch a welcome window opens; afterwards it lives in the menu bar (speech-bubble icon, top right).
>
> It coaches the user's *own* speaking during calls: pace, filler words, talk share, interruptions, steadiness. All processing is on-device (Apple Speech, SoundAnalysis, NaturalLanguage, Foundation Models, a Core ML speaker model). No audio is stored, no data leaves the Mac, no account.
>
> To test without a call: click the menu bar icon › **Listen Now**, talk for 3+ minutes (reading anything aloud works), then click **Stop**. The post-call card appears top-right with scores, one tip and a rating slider. Scores need 3 minutes of speech; shorter sessions show details without scores.
>
> Optional: Settings › Voice › **Set Up Voice Check** (30 s read-aloud). The first time, a ~30 MB speaker model downloads; it's data, not code.
>
> Permissions: Microphone (your side of the call). Speech Recognition (on-device transcription for pace and fillers). System Audio Recording, optional and only during calls: it measures the *loudness* of the other side to know when they're talking; their audio is never saved or transcribed.
>
> Tone ("warm / even / tense") comes from on-device sentiment of the user's own words and is shown for reflection only. Halen makes no health or emotion-diagnosis claims.
