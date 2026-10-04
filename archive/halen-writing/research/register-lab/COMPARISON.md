# GPT-2 vs a modern instruct model (Qwen2.5-3B-Instruct)

The request was to re-run on **Gemma E4B** as a more large-model-indicative
subject. Every Gemma checkpoint on HuggingFace is **gated** (HTTP 401 without a
license-accepted token, which this environment doesn't have), and the real E4B
checkpoint (`google/gemma-3n-E4B-it`, ~8B actual params) wouldn't fit this
4-core / 15 GB CPU box anyway. So this run uses the strongest *open*, modern,
instruction-tuned model that does fit — **Qwen/Qwen2.5-3B-Instruct** (Apache-2.0,
late-2024) — as a stand-in for "a modern, large-ish instruct model."

> To run actual Gemma E4B: set `HF_TOKEN` to a token that has accepted the Gemma
> license at huggingface.co/google/gemma-3n-E4B-it, then
> `python3 mechanism.py --model google/gemma-3n-E4B-it --dtype bfloat16`.
> The harness is model-agnostic; nothing else changes.

Same method as the GPT-2 run (next-token *register fingerprint*; see
`FINDINGS.md`), raw completion, English register lexicon. Full data:
`out/DICTIONARY.qwen2.5-3b-instruct.md`, `out/REPORT.qwen2.5-3b-instruct.md`.

## The thesis survives at scale — and sharpens for formal words

The single-word register effect is clearly present in the 3B instruct model, and
for **formal / technical / institutional** words it is *sharper* than GPT-2,
because the bigger model resolves the intended sense:

| word | GPT-2 fingerprint | Qwen2.5-3B fingerprint | change |
|---|---|---|---|
| `capital` | cities, infrastructure, redevelopment, metropolitan | **equity, asset, investors, debt, investment, ipo** | GPT-2 heard "capital *city*"; Qwen hears *financial* capital |
| `cash` | gambling, poker, liquidity, dividend | **cfo, barclays, liquidity, investors, salesforce, asset** | sharper corporate-finance register |
| `stakeholders` | ngos, policymakers, governments | **regulators, governance, audit, contractors, regulatory** | shifts from NGO/policy to corporate-governance |
| `Yo` | kobe, kendrick, rappers, lebron | **gotta, shit, dude, dudes, yeah, vibes** | current slang ("vibes", "dude") instead of 2019 NBA/rap names |

This matches **claim 2** (formal/institutional words are the strongest, cleanest
levers) and strengthens it: scale buys disambiguation.

## Slang is read literally — even more cleanly

**Claim 3** holds and sharpens. The bigger model has crisper *literal* senses, so
slang nouns collapse to them even harder:

| word | GPT-2 | Qwen2.5-3B |
|---|---|---|
| `dough` | pastry, bake, oven, gluten | **gluten, bake, baking, bread, flour** |
| `bucks` | cowboy, buffalo, panther, cow | **deer, hunters, hunter, mating, hunts** (the male-deer sense) |
| `fire` | arson, blaze, flames | flames, arson, burns, flame |

A modern instruct model is *not* better at using slang as a register lever
out of context — if anything it's more confidently literal.

## Training-provenance leakage shows up again — pointing at the new model's data

GPT-2's `Yo`→NBA/rap leak revealed WebText. Qwen leaks its own, more global and
notably **Chinese** training data — the same phenomenon (**claim 5**), different
corpus:

- `very` → thailand, **beijing, huawei, qin** — Qwen is an Alibaba model; it leaks Chinese entities.
- `assessment` → **sudan, rwanda, aleppo, riyadh, jakarta, kabul** (humanitarian/geopolitical "assessment").
- `money` → tuition, **obamacare**, taxes, poverty (US policy).

## What's new at scale: RLHF flattening + multilingual dilution

More words landed in **`neutral`** for Qwen than for GPT-2 — but this is the
*probe* hitting two scale effects, not the steering disappearing:

1. **RLHF flattening.** Instruction-tuning compresses the next-token
   distribution toward a uniform "assistant" continuation (literature:
   Kirk et al. 2023, "RLHF significantly reduces output diversity"). The
   register-marker mass is genuinely lower and noisier — note several high-hit
   words now have *negative* `mass_z` (`extremely` −0.75, `everyone` −1.69),
   where on GPT-2 the two signals agreed. The robust fingerprint method still
   recovers the register; the distributional `mass_z` check degrades.
2. **Multilingual / code contamination.** Qwen2.5 is heavily multilingual and
   code-trained, so contrastive fingerprints leak other-language tokens
   (`usted`, `jedoch`, `siêu`, `tłum`, `النار`, `geile`) and code tokens
   (`sql`, `csv`, `func`, `mysql`, `http`). Our register lexicon is English-only,
   so those tokens score zero and dilute hit counts.

## Caveat on method

These fingerprints are from **raw sentence completion**. A base model (GPT-2)
does that natively; an instruct model is mildly out-of-distribution (it wants to
*answer*, not continue), which adds noise — a chat-templated variant that
measures the register of the model's actual *response* is the natural next step.
Even so, the headline holds: **single-word register steering is real in a modern
instruction-tuned model, strongest for formal/technical words, weak-and-literal
for slang — exactly the GPT-2 pattern, just dampened by RLHF and blurred by
multilingual training.**
