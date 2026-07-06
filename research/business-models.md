# Halen — business model review

*An application of the Solo Business Idea Generation Skill v2 framework to
Halen as it exists in this repository (July 2026). A strategy write-up, not
a commitment; nothing here changes the promises in [ROADMAP.md](../ROADMAP.md).*

---

## What Halen actually is (the asset inventory)

Before scoring ideas, an honest read of what the repo contains — because the
framework's whole point is that the business is built on assets, not features.

**The product.** A local-first macOS menubar writing assistant: tone/clarity
coaching (SentimentGuard, WritingCoach, ClarityChecker), typo fixing, snippet
expansion, voice dictation, Ask Halen, and Prompt Polish. Inference routes
across Apple Foundation Models → bundled llama.cpp models (Gemma/Qwen) →
Ollama. MIT, free, signed/notarized, self-updating.

**The promises.** No cloud, no accounts, no telemetry, no subscription
commitment, free version stays free forever. These are strategic constraints
— they rule out most default SaaS monetisation, and they are also the single
most defensible thing in the repo (see 2030 test below).

**The platform surface.** This matters more than any single feature:

- An **out-of-process plugin system** (JSON-RPC over stdio, any language) with
  a manifest/permission model, a curated **Plugin Store registry**
  (`plugin-registry.json`) fetched over HTTPS, and a roadmap item for
  installing third-party plugins from URLs with signature checks.
- An **OS-level text event bus**: Accessibility-tap typing events, caret
  overlays, per-app context, plus a **browser-extension WebSocket bridge**
  that extends the event stream into Chromium DOMs. This is the hard,
  unglamorous integration work that neither a frontier model nor a weekend
  clone reproduces.
- **Proprietary research data**: `research/register-lab` — an empirical
  word → register dictionary that powers Prompt Polish. A genuine (small)
  proprietary data pipeline.
- **Trust artifacts**: open source, auditable, "your text never leaves the
  Mac" — a claim Grammarly, Notion AI, and every cloud writing tool
  structurally cannot make.

---

## Stage 1 — What recently became true

The framework says stop if nothing changed. Several things changed:

1. **Small local models crossed the usefulness threshold on Apple Silicon.**
   Sub-100ms classification and streaming rewrites with zero marginal cost
   were not practical 24 months ago. Halen exists because of this.
2. **Apple Intelligence shipped an on-device foundation model API** — free
   inference the app already routes to.
3. **Enterprise AI governance hardened.** Legal, healthcare, finance,
   defence, and government orgs now have *written policies* banning cloud
   LLMs for sensitive text. "Employees are pasting client data into
   ChatGPT" is a named risk in security reviews. The demand for
   provably-local AI is new, real, and paid for out of risk budgets.
4. **LLM token spend became a line item** — hence Reasoning Compactor.

Change #3 is the one Halen is uniquely positioned on, and the codebase's
biggest strategic asset (the privacy architecture) is aimed straight at it.

## Stage 11 first — the substitution warning

Before the ideas: the honest threat assessment. **The generic feature set
does not survive Stage 11.** "Fix my typos, rewrite this nicer" is exactly
what Apple Writing Tools, ChatGPT, and every OS-level assistant will do for
free — the roadmap itself acknowledges this with the "Writing Tools handoff"
item. If Halen's business were "sell the rewriting," it would be a wrapper
with a countdown timer.

What survives frontier improvement:

- the **trust/compliance position** (better models make local-only *more*
  capable, not less — the moat is the deployment model, not the model),
- the **event-bus + AX integration rails** (operational infrastructure),
- the **plugin registry / distribution** (marketplace liquidity, if grown),
- the **community and brand** around "AI that never phones home."

Every model below is built on those four, not on the rewrites.

---

## The candidates, scored

Framework scoring: Pain / Timing / Distribution / Monetisation / Competition
/ AI-durability / Founder-leverage, each /10; reject below 50/70.

### A. Halen for Teams — the compliance/managed-deployment layer ⭐ (56/70)

**The one-line promise:** *"The writing AI your security team will actually
approve."*

Sell to organisations that have banned Grammarly/ChatGPT for data reasons:
law firms, clinics, accountancies, government contractors, HR departments.
The individual app stays free and account-less (promises intact — accounts
and payment attach to the *organisation*, via license keys and MDM, never to
individual users). The paid layer is what orgs need and individuals don't:

- **MDM deployment profiles** (Jamf/Kandji/Mosyle) with managed settings —
  centrally pushed style guides, tone policies, snippet libraries, and
  plugin allowlists (only signed, approved plugins run).
- **Commercial license + support SLA** — the Obsidian/Bitwarden pattern:
  the license is partly "we are allowed to use this at work" paperwork.
- **On-device policy checks**: per-app target tones already exist
  (`ToneProfiles`); the enterprise version is "every outbound client email
  matches firm voice / avoids flagged language, checked locally before send."

**Pricing from value (Stage 7):** risk reduced + procurement norms →
£49–99/seat/year, £999+/year site licenses for small firms. No £5/month
anywhere.

**Distribution (Stage 6):** MDM vendor app catalogs, r/macsysadmin,
MacAdmins Slack (a genuinely dense watering hole), security-review
friendliness as SEO ("Grammarly alternative that passes security review",
"on-device writing assistant HIPAA").

**Recurring moment (Stage 9):** every message every employee sends.

**Analogues (Stage 14):** Tailscale (free personal / paid org control
plane), Bitwarden (open source + enterprise policy layer), Obsidian
(free app + commercial license), 1Password Business.

Scores: Pain 8, Timing 9, Distribution 7, Monetisation 9, Competition 7
(Grammarly *cannot* credibly go local; Apple won't do fleet policy),
Durability 9, Leverage 7. **56 — build this.**

### B. One-time Pro unlock ("Powerpack" model) — 51/70

The Alfred play: the core app stays free forever; a **£59–79 one-time**
license unlocks premium plugins — the v0.5 local knowledge index, pro Email
Reply with "cite from your notes", Mother's hardcore tier, advanced snippet
packs. One-time purchase honors the no-subscription promise to the letter;
license key via Paddle/Lemon Squeezy needs no account.

**Analogues:** Alfred Powerpack, Cold Turkey, Sublime Text, TablePlus.

Scores: Pain 6, Timing 7, Distribution 8 (in-app, existing users),
Monetisation 7, Competition 6, Durability 8 (the knowledge index is
personal-data lock-in that frontier models don't replicate — Stage 17
"proprietary feedback loop"), Leverage 9. **51 — do this first; it's the
lowest-effort revenue and it funds A.**

### C. Vertical: outbound-comms compliance for regulated firms — 55/70

The sharpest "tiny market × extreme willingness to pay" (Stage 3) cut of A.
FCA/SEC/FINRA-regulated firms are *legally required* to supervise electronic
communications; existing surveillance vendors are cloud-based, expensive,
and loathed. A Halen plugin pack that flags promissory language,
guarantees-of-returns, unapproved claims *at the caret, before send,
entirely on-device* replaces production (Stage 4: it does the compliance
reviewer's actual reading work), not management.

One obvious promise (Stage 10): *"Catches the sentence that gets you fined —
before you hit send."* Pricing: £999–4,999/year per firm without blinking.
Small enough that nobody else cared; painful enough that they pay.

Scores: Pain 9, Timing 9, Distribution 6 (compliance consultants, niche
conferences — slower), Monetisation 10, Competition 8, Durability 8,
Leverage 5 (vertical sales is real work for one founder). **55 — the best
expansion once A exists; possibly the best business here if you can stomach
the sales motion.**

### D. Plugin marketplace with paid third-party plugins — 48/70 (not yet)

Take a cut of paid plugins through the Plugin Store. This is the Stage 17
asset — marketplace liquidity + network effects, the thing that gets *more*
valuable as AI improves (coding agents make plugin supply nearly free;
distribution to Macs with AX permissions granted stays scarce). But
marketplaces need an install base first. Below the bar today; the strategic
sequence is B → A → D. Analogues: Raycast Store, Stream Deck marketplace,
Obsidian community plugins.

### E. Standalone spin-outs — rejected or parked

- **Reasoning Compactor as a dev tool/API** (~45): real pain (token spend),
  but fails Stage 11 — providers are shipping native prompt caching and
  context compaction; the frontier eats this. Keep as a store plugin.
- **Mother as a standalone blocker** (~47): proven WTP niche (Cold Turkey
  sells one-time licenses profitably) but crowded and not timing-dependent;
  better as a headline paid plugin inside B than as its own business.
- **register-lab dictionary as licensable data** (~40): interesting
  credibility asset and content-marketing engine (the FINDINGS write-up is
  genuinely linkable), not a business.

### Stage 16 veto check

Halen *is* nominally on the veto list ("another AI wrapper / writing
assistant") — it passes only because of a structural breakthrough: the
local-only architecture + OS event bus + open-source trust position is
fundamentally different from the wrapper cohort, and models A/C monetise
that difference specifically, not the wrapping.

---

## Stage 15 — force multiplication from the one core insight

The core insight: **"provably-local AI at the OS text layer, with trusted
distribution."** One insight, several skus:

| Version | What it is |
|---|---|
| Consumer | Free app + one-time Pro unlock (B) |
| Enterprise | Managed deployment + policy layer (A) |
| Vertical | Regulated-comms compliance pack (C) |
| Marketplace | Paid third-party plugins, rev share (D) |
| API | The event bus as a local platform other agents subscribe to |
| Agent-to-agent (Stage 12) | Local agents buy capabilities from the Plugin Store programmatically — plugins as machine-purchasable tools |
| Open-source | Already is — it's the trust engine, keep it |

## Stage 17 — the 2030 test

In 2030, inference is free and every OS ships a writing assistant. What's
scarce then, from this repo:

1. **Trust brand** — years of "never phoned home" is unforgeable
   retroactively. Competitors can copy features, not history.
2. **Distribution** — an installed base with Accessibility + Input
   Monitoring granted is the single hardest permission set on macOS.
3. **The plugin rails + registry** — if D reaches liquidity, Halen is the
   place local-AI capabilities get distributed, which *appreciates* as
   models improve.
4. **Enterprise policy position** (A/C) — fleet config, allowlists, and
   compliance packs are operational execution, not model quality.
5. **Personal knowledge index** (v0.5) — a proprietary on-device feedback
   loop no cloud model gets to see.

Halen gets more valuable as AI improves, provided the business is built on
1–5 and not on the quality of the rewrites.

## Recommended sequence

1. **Now:** B — one-time Pro unlock (license key, no account). Small,
   promise-compatible, funds everything else. Ship Mother-Pro + the v0.5
   knowledge index behind it.
2. **Next:** A — Halen for Teams (MDM profiles, managed style guides,
   signed-plugin allowlists, commercial license). This is the real
   business; £49–99/seat/year against risk budgets.
3. **Then:** C — one regulated vertical (pick one: legal or financial
   comms), priced £999+/year, sold through the pain of supervision
   requirements.
4. **Compounding in the background:** D — open the Plugin Store to paid
   third-party plugins once the install base justifies it.

What *not* to do: subscriptions on individuals, accounts, cloud anything,
or competing with Apple on generic rewriting. The promises in the roadmap
aren't a monetisation obstacle — they're the product.
