# Halen EQ — feature catalogue (for include / exclude decision)

Every feature surfaced by the research sweep (2026-10-04), unfiltered. Nothing
has been excluded on my judgement — the **Decision** column is yours.

- **Status:** ✅ built in `eq/` · 🧱 scaffolded (protocol exists, model not wired) · 💡 idea only
- **Evidence:** S strong (RCT / meta-analysis) · M moderate · W weak / prototype / industry claim
- **Risk flags:** NC = non-commercial licence · 🩺 medical-claim · ⚖️ consent/legal · 🎭 deepfake · 🎯 Goodhart/anxiety
- **Review** = adversarial-review verdict (see bottom section)

## A. Capture & privacy

| # | Feature | Status | Evidence / source | Tech | Flags | Review | Decision |
|---|---|---|---|---|---|---|---|
| A1 | Mic-only capture, never system audio content | ✅ | — | AVAudioEngine | | CORE — bleed means 'never others' audio' isn't yet a kept promise | |
| A2 | Auto-start when Zoom/Teams/FaceTime/Slack/etc. holds the mic (no permission prompt) | ✅ | — | CoreAudio process objects | | CORE — needs visible indicator + per-app opt-out | |
| A3 | Browser mic → ask, don't auto-start (Meet ambiguity) | ✅ | — | | | STRONG — Meet users get friction | |
| A4 | Voice enrollment (30–60 s read-aloud) → speaker embedding gate, others zeroed in RAM | ✅ | Target-speaker-ID pipeline spec. 0.95–0.98 (arXiv 2608.17972) | FluidAudio `SpeakerManager` / WeSpeaker; ReDimNet2+ | ⚖️ biometric (BIPA/GDPR) | MAYBE — biometric template (BIPA/GDPR Art 9); try A8+A20 first | |
| A5 | Random-phrase liveness in enrollment (also consent gate for any voice cloning) | 💡 | | | | WEAK — only matters if cloning | |
| A6 | Neural echo cancellation of speaker bleed using far-end reference | 💡 | LocalVQE: far-end leakage 34%→1.1% | FluidAudio `LocalVqeManager` (beta) + process tap | | STRONG — accuracy infrastructure | |
| A7 | Far-end **level-only** meter (VAD on call-app audio, samples discarded) → talk ratio, interruptions, latency | ✅ | Novel; no prior art found locally | Core Audio process tap + Silero VAD | ⚖️ needs audio-capture TCC prompt | CORE — without it Presence is hollow | |
| A8 | Far-end energy veto for gate (mic correlates with tap → not you) | 💡 | | | | STRONG — cheap, no biometrics | |
| A9 | Foreground/near-field VAD without enrollment | 💡 | Mamba-FVAD (arXiv 2609.19856) — no weights | | | WEAK — no weights | |
| A10 | Target speaker *extraction* (remove others' voices, not just gate) | 💡 | WeSep, TargetVoice — no CoreML | | | WEAK — gating suffices | |
| A11 | In-person mode (hotkey start, diarize "me vs not me", keep only others' timestamps) | 💡 | | LS-EEND / Sortformer | ⚖️ all-party states | HARMFUL — covert in-person analysis, all-party states | |
| A12 | Encrypted per-session store, key in Keychain (this-device-only) | ✅ | | CryptoKit AES-GCM | | CORE | |
| A13 | Tiered forgetting: audio never written · transcript N days (default 7) · numbers forever. Transcript not persisted until A4 gate exists | ✅ (transcripts opt-in, voice-checked only) | | `Retention` | | CORE — transcript default ≤7 days (now 7) | |
| A14 | "Forget everything" (files + key) | ✅ | | | | CORE | |
| A15 | Secure-Enclave-wrapped key, optional Touch ID to open dashboard | 💡 | | | | MAYBE — friction | |
| A16 | No network entitlement / sandboxed app | 💡 | | | | CORE — most credible privacy proof | |
| A17 | Moment clips: keep 10 s of your own audio for 72 h, encrypted | 💡 | Video self-modeling (M) | | | HARMFUL — one exception kills 'audio is deleted' | |
| A18 | Voice-convert stored clips to an average voice (anonymised) | 💡 | | Seed-VC (archived), Chatterbox VC | | WEAK | |
| A19 | "Notify participants" helper (paste-able line for chat) | 💡 | | | ⚖️ | STRONG — trivial, defuses consent anxiety | |
| A20 | Headphones vs speakers route detection → gate strictness + confidence flag | 💡 | | CoreAudio default output | | STRONG — confidence flag = honesty | |

## B. Transcription

| # | Feature | Status | Evidence / source | Tech | Flags | Review | Decision |
|---|---|---|---|---|---|---|---|
| B1 | On-device ASR with word timestamps, zero download | ✅ | ~2% WER clean speech. **Tested here: keeps um/uh (writes 'uh' as 'ah')** | Apple SpeechAnalyzer | | CORE — validate '?' punctuation on conversation | |
| B2 | Parakeet TDT v2/v3 batch re-transcription for better timings | 💡 | ~190× RT on M4 Pro | FluidAudio `AsrManager` | | MAYBE | |
| B3 | Streaming live captions of your side | 💡 | | Nemotron streaming / Parakeet EOU | | HARMFUL — splits attention mid-call | |
| B4 | **Acoustic filled-pause ("um/uh") detector** — ASRs drop fillers | ✅ | ASR filler recall 0.4–7% (arXiv 2609.20828) | Swift DSP (`FilledPauses`) | | STRONG — needs labelled eval set | |
| B5 | Trained filler spotter (PodcastFillers, TC-ResNet ~100K params) | 💡 | | CoreML | | STRONG | |
| B6 | CrisperWhisper verbatim second pass (fillers, false starts, repetitions) | 💡 | Disfluency F1 93.5 (v2) | WhisperKit | NC (commercial licence available) | WEAK — NC weights (verified CC-BY-NC-4.0) | |
| B7 | False starts / repetitions counter | 💡 | | CrisperWhisper or LLM | | WEAK — punishes stutterers | |
| B8 | Multilingual coaching | 💡 | Parakeet v3: 25 langs | | | MAYBE — ship English-only | |

## C. Delivery metrics (Clarity)

| # | Feature | Status | Evidence | Tech | Flags | Review | Decision |
|---|---|---|---|---|---|---|---|
| C1 | Pace (wpm) vs *your* comfortable band | ✅ | Speech-rate band, inverted-U (M) | | | CORE — but commoditised | |
| C2 | Articulation rate (excl. pauses) | ✅ | | | | WEAK — keep internal | |
| C3 | Filler rate vs your baseline, never "zero fillers" goal | ✅ | Fox Tree; Voss & Niebuhr (W-M) | | 🎯 | MAYBE — biggest Goodhart trap | |
| C4 | Hedging rate (lexicon) | ❌ removed (YAGNI) | Hedges cost confidence but aid receptiveness (M) | | | WEAK — contradicts receptiveness evidence (now informational) | |
| C5 | Hedge classifier model | 💡 | BERTweet-Hedge F1 ~0.88 | CoreML | | WEAK | |
| C6 | Vocal variety / monotone (pitch SD in semitones) | ✅ | Niebuhr charisma (M) | YIN (vDSP) | | STRONG | |
| C7 | Better pitch tracker | 💡 | SwiftF0: 96K params, beats CREPE | ONNX→CoreML | | STRONG — fix pitch upstream | |
| C8 | Uptalk on statements | ❌ removed (YAGNI) | Ponsot PNAS 2018; Jiang & Pell (M) | | bias risk — opt-in framing | HARMFUL — gender/dialect-coded (now hidden) | |
| C9 | Vocal fry at phrase ends | 💡 | Anderson 2014 (W-M, mostly listener bias) | DeepFry / jitter+HNR | gender bias | HARMFUL — listener bias, never ship | |
| C10 | Loudness dynamics / trailing off | 🧱 | | RMS (have data) | | MAYBE — mic distance confound | |
| C11 | Pause analysis: considered (0.3–2 s) vs hesitation | ✅ | | | | MAYBE | |
| C12 | Voice quality: CPP, HNR, jitter, shimmer → tension / breathiness / fatigue | 💡 | | Swift DSP (openSMILE is GPL/NC) | | WEAK — near-medical | |
| C13 | Turn-end contour (falling = authority) | 💡 | Ponsot (M-S) | | | MAYBE — same bias as C8 | |
| C14 | Word-level emphasis coaching | 💡 | | | | WEAK | |

## D. Listening metrics (Presence)

| # | Feature | Status | Evidence | Tech | Flags | Review | Decision |
|---|---|---|---|---|---|---|---|
| D1 | Talk share, context-aware target (1:1 ≈ 50%, groups differ) | ✅ (needs A7) | CSCW 2025 (M-S); babble hypothesis (M) | | | CORE | |
| D2 | Interruptions per 10 min | ✅ (needs A7) | | | | STRONG — needs D3; jitter fakes overlaps | |
| D3 | Cooperative vs competitive overlap distinction | 💡 | Tannen; arXiv 2407.14940 (M) | | ND-fairness | MAYBE | |
| D4 | Response latency "connection" metric (diagnostic, not a target) | ✅ (needs A7) | Templeton PNAS 2022 (S) | | 🎯 | WEAK — network latency swamps effect | |
| D5 | Longest turn / monologue alert | ✅ | | | | CORE — best live-cue candidate | |
| D6 | Questions asked | ❌ removed (YAGNI) | Huang JPSP 2017 (S) | | | STRONG evidence / weak detector (now informational) | |
| D7 | **Follow-up** questions specifically | 💡 | Huang 2017 (S) — strongest single EQ predictor | local LLM | | MAYBE — needs other side's words | |
| D8 | Your backchannels ("mm-hm") rate — active listening | 💡 | VAP (M) | VAP / short-segment heuristic | | MAYBE — often muted | |
| D9 | Conversational receptiveness score | 💡 | Yeomans 2020 (S) | port `politeness::receptiveness` | | MAYBE — validated on text | |
| D10 | Politeness features (gratitude, apology, please) | 💡 | (S) | | | WEAK | |
| D11 | Listening quality: paraphrase / validation | 💡 | Itzchakov (S) | local LLM rubric | | WEAK — impossible one-sided | |
| D12 | Empathy facets (EPITOME) | 💡 | Sharma 2020 (M) | RoBERTa | context-blind | WEAK | |
| D13 | "We" vs "I" | 💡 | (M) | lexicon | | WEAK | |
| D14 | Per-person relationship ledger (talk share, latency per counterpart via calendar) | 💡 | | EventKit, local | | MAYBE — sticky but a colleague dossier | |

## E. Emotion & regulation (Composure)

| # | Feature | Status | Evidence | Tech | Flags | Review | Decision |
|---|---|---|---|---|---|---|---|
| E1 | Activation spikes vs calm baseline (pitch + loudness + pace) | ✅ | Stress→F0 meta-analysis SMD ~0.55 (S) | DSP | label "activation" never "angry" | CORE (baseline contamination fixed) | |
| E2 | Escalation drift (hotter late vs early) | ✅ | | | | STRONG | |
| E3 | Calm-voice calibration (45 s) | ✅ | | | | STRONG — read-aloud ≠ conversational calm | |
| E4 | Dimensional arousal/valence/dominance model | 💡 | Valence CCC ≤ 0.68 | 3loi Odyssey WavLM (MIT, MSP data caveat) | data-licence review | WEAK — valence ≈ chance in the wild; MSP data licence | |
| E5 | Always-on tiny arousal gauge | 💡 | | Wav2Small 72K params | NC (CC-BY-NC-SA — corrected) | WEAK — licence is actually CC-BY-NC-SA | |
| E6 | Categorical emotion timeline | 💡 | ~72% IEMOCAP, acted | emotion2vec+ (MLX Swift port exists) | | HARMFUL — acted-speech labels on your boss call | |
| E7 | 40-emotion fine vocabulary for reflection copy | 💡 | | LAION Empathic-Insight (CC-BY) | | WEAK — confident fiction | |
| E8 | **Recovery curve**: time to return to baseline after a spike (WHOOP "recovery" analogue) | 💡 | | | | STRONG — the real WHOOP analogue | |
| E9 | Laughter rate (warmth/rapport) | ✅ | | voc2vec / LAION burst | | MAYBE | |
| E10 | Sigh detection (fatigue/frustration) | 💡 | | | | WEAK | |
| E11 | Goal-based style scoring ("I want to sound calm and authoritative") | 💡 | | ParaSpeechCLAP (MIT) | | MAYBE | |
| E12 | Situation-appropriateness of tone | 💡 | SpeechSense 2026 datasets | | | WEAK | |
| E13 | Confidence score model | 💡 | F1 0.75 (arXiv 2605.12387) | | | WEAK | |
| E14 | Post-spike affect-labelling prompt ("name what you felt") | 💡 | Lieberman 2007 (S) | | | STRONG | |
| E15 | Post-call cyclic-sighing 2–5 min reset, triggered by activation | 💡 | Balban 2023 RCT (S) | | | STRONG — offer, not reprimand | |
| E16 | Absolutist-language trend ("always/never") | 💡 | Al-Mosaiwi 2018 (M) | lexicon | 🩺-adjacent | HARMFUL | |
| E17 | "I-talk" trend | 💡 | r ≈ .10 (M, weak) | | 🩺-adjacent | HARMFUL | |
| E18 | Depression/anxiety drift (Kintsugi DAM, Apache) | 💡 | sens 71% / spec 74% | | 🩺 FDA/MDR; EU AI Act | HARMFUL — medical device | |
| E19 | Readiness score ("today you may run hot") from yesterday's load | 💡 | No direct evidence (W) | | 🎯 orthosomnia | HARMFUL — orthosomnia | |
| E20 | Audio-LLM deep caption (Qwen3-Omni Captioner, 32 GB+ Macs) | 💡 | Open SOTA paralinguistic captioner | MLX 4-bit ~18 GB | | WEAK — 18 GB RAM | |
| E21 | Gemma 4 E4B audio clip description | 💡 | 30 s limit; LLMs under-use prosody | mlx-vlm | | WEAK | |

## F. Coaching loop & UX

| # | Feature | Status | Evidence | Tech | Flags | Review | Decision |
|---|---|---|---|---|---|---|---|
| F1 | Menubar three-ring summary | ✅ | | | | CORE — no totals | |
| F2 | One takeaway + one "next time" per call, from numbers only | ✅ | | Foundation Models `@Generable` | | CORE — retention lives here | |
| F3 | Weekly single focus (worst factor) | ✅ | Michie 2009 goal+review (S) | | | CORE — pick most *improvable*, not worst | |
| F4 | Sparse live cue (menubar glow) for monologue / pace spike, off by default | 💡 | Rhema; WSCoach (M) | | | STRONG — monologue only | |
| F5 | Haptic live cue via Apple Watch / trackpad | 💡 | (W) | | | WEAK | |
| F6 | No live emotion cues — reflection only | (design rule) | arXiv 2011.06529 (M) | | | CORE | |
| F7 | Pre-meeting priming card from calendar + history with that person | 💡 | Implementation intentions (M) | EventKit | | STRONG — best habit hook | |
| F8 | 60-s post-call reflection (highlight / label / intention) | 💡 | (M) | | | MAYBE — only after notable calls | |
| F9 | "Better phrasing" suggestions for your own sentences (post-hoc) | 💡 | HAILEY RCT +19.6% empathy (S) | local LLM | | STRONG — but forces transcript retention | |
| F10 | Best-moment replay (not blooper reel) | 💡 | Self-modeling (M) | needs A17 | | MAYBE — depends on A17 | |
| F11 | Forgiving streaks (freeze days, weekly) | 💡 | Silverman 2023 (M-S) | | 🎯 | WEAK | |
| F12 | No permanent single aggregate "EQ score" | (design rule) | orthosomnia (M) | | | CORE | |
| F13 | Meeting-type toggle / context presets (1:1, pitch, all-hands, interview) | 💡 | Novecs CSCW 2025 (M) | | | CORE | |
| F14 | Stuttering mode (disable filler/repetition metrics) | 💡 | (M) | | fairness | STRONG | |
| F15 | Neurodivergent-affirming framing ("translation not correction") | 💡 | double-empathy (M) | | fairness | STRONG | |
| F16 | Cultural-style presets (high-involvement vs considerate) | 💡 | Tannen (M) | | | MAYBE | |
| F17 | User chooses which metrics are goals at all | ✅ | | | | CORE | |
| F18 | Spoken daily debrief | 💡 | | Kokoro on ANE (FluidAudio) | | WEAK | |
| F19 | Deep-talk nudges | 💡 | Kardas 2022 (S) | | | MAYBE | |
| F20 | Export a summary for your human coach/therapist | 💡 | | | | MAYBE | |

## G. Voice synthesis (the new TTS wave)

| # | Feature | Status | Evidence | Tech | Flags | Review | Decision |
|---|---|---|---|---|---|---|---|
| G1 | **"Hear it better" — edit your *real* clip** (cut fillers, slow, soften) | 💡 | Tencent AuK (MIT, Sep 2026) — CUDA only | AuK / Step-Audio-EditX | 🎭 | MAYBE — best 'aha' but CUDA-only | |
| G2 | "Hear it better" — re-synthesise in your cloned voice with calmer delivery | 💡 | | Qwen3-TTS (Apache) via mlx-audio | 🎭 | HARMFUL — liability + uncanny | |
| G3 | Same improvement in a neutral stock voice (no clone) | 💡 | | Kokoro / Pocket TTS on ANE | | MAYBE | |
| G4 | Prosody dial: rate / pitch range / warmth sliders on one sentence | 💡 | | IndexTTS-2 (licence?) / Qwen3 | | WEAK | |
| G5 | Calm vs rushed vs defensive triad | 💡 | | | | WEAK | |
| G6 | Shadowing drill: hear improved line, repeat, get prosody distance | 💡 | | DTW over F0/energy | | MAYBE | |
| G7 | Rehearsal partner (cascade STT→LLM→TTS) for hard conversations | 💡 | Yoodli-style (W-M) | | | MAYBE — different product | |
| G8 | Full-duplex rehearsal partner (interrupts, backchannels) | 💡 | | Moshi MLX / PersonaPlex (CUDA) | | WEAK | |
| G9 | Roleplay difficulty knobs (hostility, interrupt rate) | 💡 | | | | WEAK | |
| G10 | Pre-meeting 60 s audio warm-up / pace metronome | 💡 | | | | MAYBE | |
| G11 | "Future you" before/after reel from real recordings | 💡 | | needs A17 | | WEAK | |
| G12 | AudioSeal watermark on all synthetic audio + "AI re-voiced" label | 💡 | | AudioSeal (MIT) | | STRONG — mandatory if any synthesis | |
| G13 | Block arbitrary-text TTS in cloned voice (only rewrites of your own sentences) | (safety rule) | | | 🎭 | CORE (conditional) | |
| G14 | Coach persona voice (designed, not cloned) | 💡 | | Qwen3 VoiceDesign / OmniVoice | | WEAK | |
| G15 | "How it landed" — re-voice your line as the other person might have heard it | 💡 | speculative | | | HARMFUL — 'gaslighting machine' | |

## H. Platform / tiers

| # | Feature | Status | Notes | Review | Decision |
|---|---|---|---|---|---|
| H1 | Model tiering by RAM (8 GB: Apple FM only; 16 GB: + 4B MLX; 32 GB+: Qwen3-Omni) | 💡 | | MAYBE — ship Apple FM only | |
| H2 | Re-use Halen's llama.cpp / Ollama router as fallback LLM | 💡 | | WEAK | |
| H3 | Open-source the capture + gating pipeline (verifiable privacy) | 💡 | | STRONG — cheapest trust lever | |
| H4 | iPhone companion for in-person / phone calls | 💡 | | MAYBE | |

---

## I. Missing features the adversarial review says a 10x product needs

| # | Feature | Why | Status | Decision |
|---|---|---|---|---|
| I1 | **Outcome anchoring**: one-tap 👎/👌/👍 "how did that go?" → learn which of *your* metrics predict *your* good calls; coach only on those | ✅ | 💡 | |
| I2 | **"That's wrong" button** on every factor | ✅ | 💡 | |
| I3 | Measurement honesty: per-metric confidence, "not enough speech" states, trend arrows only beyond minimal detectable change | Trust | partly ✅ (3-min minimum) | |
| I4 | Per-device & per-context baselines (AirPods vs built-in; 1:1 vs presenting) | dB/pitch shift with device | partly ✅ (loudness now session-relative) | |
| I5 | Exclusions: "don't analyse this call", auto-skip by calendar keyword (therapy, doctor) | Consent & comfort | 💡 | |
| I6 | Meeting-load "strain" context from calendar (back-to-backs, late calls) | Explains Composure dips | 💡 | |
| I7 | Self-set intention → post-call yes/no check | User-owned goals beat app-chosen | 💡 | |
| I8 | Day-0 value: synthetic demo session in onboarding | First 5 calls otherwise empty | 💡 | |
| I9 | IT/admin pack: privacy whitepaper, entitlement proof, MDM-friendly | Work laptops | 💡 | |
| I10 | Raw CSV export | Trust, power users | 💡 | |

## Built in round 2 (2026-10-04)

- **Voice check** (A4): FluidAudio WeSpeaker embeddings, 30 s enrollment that also sets calm pitch; self-calibrated threshold; fails closed.
- **Far-end level meter** (A7): Core Audio process tap on the call app, level only, skips headset-mic buffers → talk share, interruptions, response latency.
- **Tone** (new): positive/negative from your own words (Apple on-device sentiment) + laughs (Apple SoundAnalysis), shown as a dot-matrix face — never scored.
- **Outcome anchoring** (I1): post-call floating card with dot slider; "Your good calls" insight after 6 ratings.
- **"Not right?"** (I2): per-factor dispute; drops out of score, focus and learning.
- **Per-app modes**: Listen automatically / Ask first / Never, per installed call app; browsers default to Ask.
- **Optional transcript saving**: off by default; only possible with voice check on; 1/7/30 days.
- **Design**: Nothing-OS-style dot-matrix language (Doto font, OFL), dot rings, dot waveform, dot timeline, per-dimension accent colours, red = heated.
- **YAGNI cuts**: uptalk, hedges, questions, discourse markers, pauses, articulation rate, unused baseline stats, Retention struct, gate/far-end protocols.

## Adversarial review — summary

Three adversarial passes ran on 2026-10-04: a **fact-check** of every model/licence/paper claim, a **product & ethics** attack on this catalogue, and a **code** review of `eq/`.

### Fact-check corrections (primary sources)
- **Wav2Small is CC-BY-NC-SA-4.0**, not CC-BY — can't ship commercially.
- **KittenTTS 2** is ternary (~1.6 bit), and its licence requires a paid licence once you pass **$1M revenue *or* $1M cumulative funding** — i.e. immediately for any VC-funded company.
- **CrisperWhisper weights: CC-BY-NC-4.0**; **emotion2vec+ uses the custom FunASR licence** ("reference and learning purposes"); **3loi Odyssey is MIT but trained on academic-only MSP-Podcast**; audEERING msp-dim is CC-BY-NC-SA.
- The "Parakeet drops fillers (0.4–4 %)" paper tested **Parakeet 110M TDT-CTC**, not 0.6B v3. **Our own test: Apple SpeechTranscriber keeps fillers** (7/7 on synthetic speech; "uh"→"ah").
- Tencent AuK verified (MIT, 1.5B, Sep 9 2026, emotion editing) — but filler removal isn't an explicit feature.
- FluidAudio v0.17.5 verified; `LocalVqeManager` (AEC) is **beta** and needs a far-end reference; some models need macOS 15.
- **EU AI Act Art 5(1)(f)**: selling to employers for use on staff = prohibited. Individual personal use = arguably exempt, work use = grey. **BIPA**: on-device-only lowers but doesn't eliminate risk (*Hazlitt v. Apple*).
- Verified: Templeton 2022, Huang 2017, Balban 2023, Yeomans 2020; Poised shutdown (Oct 8), Teams Speaker Coach retired (Aug 2025), Hume expression API shut (Jun 14 2026).

### Product attack — five ways it fails & kill-tests
1. **Retention cliff** → kill-metric: % of week-1 users opening ≥3 takeaways/week in week 4 unprompted. **< 35 % → stop.**
2. **Validity** → 10 users × 2 similar calls, ICC per metric; anything < 0.6 becomes a hidden diagnostic.
3. **Wellbeing backfire** (socially anxious users ruminate) → self-consciousness item at baseline & week 4; kill if it rises in ≥ 20 %.
4. **Trust/legal on work Macs** → no-network entitlement, open-source capture, IT one-pager; ask 20 managers "would you install this at work?"
5. **Platform** (Teams/Zoom do pace & fillers free) → compete only on cross-app longitudinal baseline, Composure/recovery, verifiable privacy.

**Reviewer's proposed v1 (12):** A1+A3, A2 (+indicator), A7, A12+A13+A14, A16, D1, D5 (+F4 glow), C1, E1+E2, F2, F13+F17, I1+I2. Fillers/hedges/uptalk/questions logged but hidden.

### Scoring fixes already applied in code
Mean (not sum) of penalties so missing factors aren't free points · no score under 3 min of speech · skills scored against fixed targets (no self-ratchet) · Composure: ≥2 of 3 channels × ≥2 consecutive windows, loudness relative to session median (device-independent), calm baseline fed only from calm sessions' quieter windows · fillers flagged only when heavy (z ≥ 1.5) · hedges, questions informational · uptalk hidden.

### Code-review fixes already applied
YIN could return negative F0 → NaN → crash (fixed + fuzz test) · start/stop race could leave mic on (new `.starting` state) · chunk ordering (single AsyncStream consumer, drained before finish) · transcript never persisted until voice gate exists · retention now hourly/on save/on setting change · Bluetooth route change re-taps · Keychain only mints a key on `errSecItemNotFound`; "forget everything" re-keys in place and orphaned files are purged · transcriber can't hang "analysing" (120 s timeout) · noise floor ignores gated silence · browser helper processes matched by prefix.

**Still open from code review:** far-end meter + voice gate not wired (Presence lacks talk share/interruptions); mixed-speaker 1.5 s windows accepted whole; uptalk end-of-session edge case.
