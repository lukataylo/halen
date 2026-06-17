# Register Lab

A small research tool for understanding **prompting strategies for next-token
prediction** — specifically the folk claim that *"if I use a word people use on
Reddit, I get a Reddit-style answer."*

It tests that claim empirically and then produces the deliverable: a
**word → register dictionary** mapping near-synonyms to the writing style each
one steers the model toward.

## The idea

A language model predicts the next token from everything before it. Word choice
is part of "everything before it." Words carry a *register* — a statistical
fingerprint of the contexts they appear in. `hot take` lives on Reddit;
`assessment` lives in reports. When you put one of them in your prompt, you tilt
the model's continuation toward that word's home register, even though the two
words *mean* the same thing.

This tool isolates that effect by changing **exactly one word** at a time.

## How it works

1. **Synonym clusters** (`clusters.py`) — sets of words with the same meaning
   but different register (e.g. `opinion / take / hot take / assessment /
   position`), each dropped into neutral **carrier sentences** with a `{w}` slot.
2. **The model** (`model.py`) — a causal LM (default **GPT-2**) gives two views:
   - `generate` — full sampled continuations (what you'd read).
   - `next_token` — the raw probability distribution over the next token (the
     mechanism, before any text is emitted).
3. **The instrument** (`lexicons.py`) — auditable marker lists for seven
   registers (Reddit/casual, academic, corporate, Gen-Z slang, legal/formal,
   marketing hype, technical) plus structural metrics (contractions, hedging,
   sentence length, emoji…). Every output is scored as marker density per 100
   words.
4. **Two analyses:**
   - `exam.py` — the **generation study**: sample full continuations per variant
     (the "what you'd actually read" view) and keep example outputs.
   - `mechanism.py` — the **authoritative analysis**: read the next-token
     distribution directly, take each word's distinctive *register fingerprint*
     (the tokens it promotes over its synonyms), and classify register from that
     fingerprint. This is what builds the dictionary. See `FINDINGS.md` for why
     fingerprint-classification beats counting markers in generations.

### Why GPT-2

GPT-2's WebText training corpus was scraped from Reddit-outbound links, and it
has no instruction-tuning to flatten register. That makes its style priors
unusually legible — the perfect subject for *seeing* next-token register effects.
A modern instruction-tuned model dampens the effect (RLHF pulls everything
toward one helpful-assistant voice) but does not remove it.

## Run it

```bash
pip install torch --index-url https://download.pytorch.org/whl/cpu
pip install transformers
python3 exam.py --samples 6 --tokens 60   # generation study (~10 min on CPU)
python3 mechanism.py                       # authoritative dictionary (~30 s)
python3 exam.py --quick                    # fast smoke run
# both accept --model gpt2-medium (cleaner, ~3x slower)
```

## Outputs

| file | what |
|---|---|
| `FINDINGS.md` | **read this first** — the written conclusion + curated dictionary |
| `RELATED_WORK.md` | the findings cross-checked against papers, vendor docs, and prompt libraries |
| `out/DICTIONARY.md` | auto-generated word→register dictionary, grouped by register |
| `out/dictionary.json` | same, machine-readable (with fingerprints + mass-z) |
| `out/REPORT.md` | mechanism: per-cluster fingerprints and labels |
| `out/generation_study.md` | generation: sampled continuations + examples |
| `out/raw.json`, `out/mechanism.json` | full audit trails |

## Caveats

- z-scores are **relative within a cluster**, so a `+1.5` for one word means it
  out-leaned its own synonyms, not the language at large.
- A 124M model is noisy; treat single low-z rows as suggestive, the aggregate
  pattern as the result. `gpt2-medium`/`-large` sharpen it.
- The lexicons are diagnostic, not exhaustive — they are designed to be edited.
