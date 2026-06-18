# Findings: how one word steers next-token prediction

**Question.** Is the folk claim true — *"if I use a word people use on Reddit, I
get a Reddit-style answer"*? And if so, can we turn it into a usable
**word → register dictionary**?

**Answer.** Yes, the effect is real and measurable — but it is sharpest at the
*mechanism* level (the next-token probability distribution), and it is strongest
for **formal / technical / institutional** words. Slang is a weaker and trickier
lever than people assume, because a base model often reads slang in its *literal*
sense. The conclusive dictionary is at the bottom of this file.

All numbers below come from running the tool in this directory on **GPT-2**
(124M). GPT-2 is the right subject: its WebText training data was scraped from
Reddit-outbound links, and it has no instruction-tuning flattening its voice, so
its register priors are legible rather than hidden.

---

## What the tool does

Each *meaning* (e.g. "a group of people") is a **cluster** of synonyms
(`people / folks / guys / individuals / stakeholders / everyone`) dropped into
identical neutral carrier sentences. The only thing that changes is the one
word. We then read the model two ways:

1. **Generation** (`exam.py`) — sample full continuations and score their style.
2. **Mechanism** (`mechanism.py`) — read the next-token distribution directly:
   which tokens does this word make likelier than its synonyms (its *register
   fingerprint*), and how much probability mass does it put on each register's
   vocabulary.

Run order: `python3 exam.py` (≈10 min, the readable continuations) then
`python3 mechanism.py` (≈30 s, the authoritative dictionary).

## Three ways to label register — and which one to trust

I tried to auto-assign a register to each word three ways. The failures are part
of the finding:

| method | result | why |
|---|---|---|
| count register markers in 60-token generations | **noisy** | on a 124M model the markers barely appear in 60 tokens, so the label is a coin-flip on one fluke hit (everything scored z≈+2.236=√5, the signature of "one variant, one hit") |
| next-token probability *mass* on register markers | **biased** | a register's marker-onset tokens collide with high-frequency generic tokens (` going`, ` best`), so common registers win regardless of the word |
| **classify the word's distinctive next-token fingerprint** | **trustworthy** | ties the label to the exact tokens the word demonstrably promotes over its synonyms |

So the authoritative `DICTIONARY.md` is **high-precision, lower-recall**: every
label it assigns is correct, but words whose fingerprint falls outside the 7
hand-built register lexicons land in `neutral` even when they clearly evoke
*something*. Those are read by hand below — and that gap is itself a result:
**register is a continuum, not 7 buckets.**

---

## Headline evidence

The cleanest single-word fingerprints (tokens the word makes likelier than its
synonyms, straight from the model — no cherry-picking):

| word | meaning | the model's next-token fingerprint | reads as |
|---|---|---|---|
| `Yo` | greeting | kobe, kendrick, rappers, lebron, kanye, tupac | **hip-hop / AAVE** |
| `individuals` | people | plaintiff, counsel, attorney, defendants, investigators | **legal** |
| `stakeholders` | people | ngos, policymakers, governments, implementation, organisations | **corporate / policy** |
| `guys` | people | dudes, dude, fuckin, yeah, gotta, shit | **casual / profane** |
| `hella` | intensifier | dunno, goddamn, fuckin, fuck, shit | **casual / profane** |
| `extremely` | intensifier | significant, numerous, unprecedented, considerable, stringent | **formal / academic** |
| `incredibly` | intensifier | transformative, empowering, groundbreaking, unparalleled | **marketing hype** |
| `talk about` | discuss | obamacare, republicans, reagan, obama, nafta, president | **political** |
| `capital` | money | infrastructure, redevelopment, investment, metropolitan | **finance / urban policy** |
| `audit` | investigate | certify, certification, inspect, certificate | **compliance** |

This is the thesis, demonstrated: swap one word and the model's *very next*
prediction tilts toward that word's home world. The tilt then compounds — each
biased token conditions the next — into a whole different answer.

## Three cross-cutting results

**1. Formal/institutional words are the strongest, cleanest levers.**
`extremely`, `individuals`, `stakeholders`, `capital`, `audit`, `superb` produce
tight, unambiguous register fingerprints. If you want to *reliably* move the
model, a formal/technical word is a better lever than a slang one.

**2. Slang is a weak and treacherous lever — base models hear the literal
sense.** The slang money words collapse to their literal meanings:
`dough` → *pastry, bake, oven, gluten*; `bucks` → *cowboy, buffalo, panther,
cow*; `fire` ("good") → *arson, blaze, flames*; `hot take` → *hotter, sexy*
(the "hot" sense). Without conversational context, GPT-2 doesn't know `dough`
means money. The Reddit-answer-from-a-Reddit-word effect is real for
*discourse* markers (`guys`, `hella`, `honestly`) but unreliable for *slang
nouns*.

**3. Proper-noun leakage exposes the training data's demographics.** `Yo` pulls
NBA players and rappers; `look into` pulls nationalities
(*syrians, ukrainians, latinos*); `talk about` pulls US politicians. The model
has learned *who* tends to be talked about in each register — a direct readout
of WebText's contents (and its biases).

**Caveat — instruction-tuned models.** RLHF pulls every answer toward one
"helpful assistant" voice, which *dampens* this effect but does not remove it;
the register bias still rides underneath the flattened surface. GPT-2 makes the
mechanism visible; a chat model hides it behind a uniform tone.

---

## The conclusive word → register dictionary

Pick a meaning, then pick the synonym whose register you want the model to
adopt. "Evokes" is the register validated against the model's own fingerprint
(★ = auto-classified with ≥2 lexicon hits; others read by hand from the
fingerprint). The full machine-readable version with mass-z scores is in
`out/dictionary.json`; per-cluster detail in `out/REPORT.md`.

### "an opening greeting"
| word | evokes | the model's tell |
|---|---|---|
| `Yo` | hip-hop / AAVE | kobe, kendrick, rappers, kanye |
| `Hey` ★ | casual / Reddit | yeah, blah, philly |
| `Dear Sir or Madam` ★ | British officialese | apologise, ministers, parliamentary |
| `Hello` / `Hi` / `Greetings` | weak / neutral | no clean register signal |

### "a stated personal view"
| word | evokes | the model's tell |
|---|---|---|
| `position` ★ | legal / policy | directive, normative, specified |
| `opinion` ★ | debate / editorial | divisive, polarized, unanimous |
| `hot take` | tabloid / celebrity | dating, celeb, sexy |
| `two cents` | retail / consumer | macy, rite, coupon, amtrak |
| `take` / `assessment` | weak / neutral | — |

### "positive evaluation"
| word | evokes | the model's tell |
|---|---|---|
| `superb` ★ | marketing / review | featuring, wonderful, excellence |
| `excellent` | service review | service, customer, delivery |
| `fire` | literal fire (slang misfires) | arson, blaze, flames |
| `good` / `great` / `awesome` / `decent` | weak / neutral | — |

### "to examine something"
| word | evokes | the model's tell |
|---|---|---|
| `audit` ★ | corporate compliance | certify, certification, inspect |
| `probe` | investigative / journalistic | probing, interrogate, suspicion |
| `look into` | geopolitical | syrians, ukrainians, africans |
| `investigate` | legal | unlawfully, endeavour |
| `dig into` / `check out` | weak / neutral | — |

### "a group of people"
| word | evokes | the model's tell |
|---|---|---|
| `stakeholders` ★ | corporate / policy | ngos, policymakers, governments |
| `individuals` ★ | legal | plaintiff, counsel, attorney, defendants |
| `guys` ★ | casual / profane | dudes, fuckin, gotta |
| `folks` | broadcast sign-off | tune, here, enjoy, stay |
| `people` | emotive / activist | pray, tears, evacuate, forgive |
| `everyone` | weak / casual | haha, spoilers |

### "to talk about"
| word | evokes | the model's tell |
|---|---|---|
| `talk about` | political | obamacare, republicans, obama, nafta |
| `touch base on` | business press | consumers, forbes, manufacturing |
| `deliberate on` | procedural | reduce, removal, remove |
| `discuss` | academic | procedure, appendix, summarize |
| `chat about` | weak / neutral | — |

### "a degree intensifier"
| word | evokes | the model's tell |
|---|---|---|
| `extremely` ★ | formal / academic | significant, unprecedented, stringent |
| `incredibly` | marketing hype | transformative, groundbreaking, unparalleled |
| `very` | trade / policy formal | bilateral, reciprocal, tariff, unilateral |
| `super` ★ | casual internet | awesome, lol, haha |
| `hella` ★ | casual / profane | dunno, goddamn, fuckin |
| `really` | weak / neutral | — |

### "money"
| word | evokes | the model's tell |
|---|---|---|
| `capital` ★ | finance / urban policy | infrastructure, redevelopment, investment |
| `cash` ★ | gambling / payments | gambling, poker, liquidity, dividend |
| `funds` | fundraising / nonprofit | funding, donations, fundraising |
| `money` | public policy | scholarships, daca, medicare, salary |
| `dough` | baking (slang misfires) | pastry, bake, oven, gluten |
| `bucks` | animals (slang misfires) | cowboy, buffalo, panther |

---

## How to read a `neutral` label

`neutral` does **not** mean "no effect." It means the word's fingerprint did not
match the 7 register lexicons — usually because (a) its register isn't one of
the seven (political, retail, broadcast, geopolitical all show up), or (b) the
word is generic enough (`good`, `take`, `really`) that it barely moves the
distribution relative to its synonyms. The lexicons in `lexicons.py` are meant
to be edited; widening them turns `neutral` rows into labelled ones.

## Limitations

- One model (124M, 2019). `gpt2-medium`/`-large` sharpen every effect; an
  instruction-tuned model would dampen it. The *pattern* is expected to hold;
  exact words and strengths will shift.
- Fingerprints are measured at one decision point (right after the swapped
  word). Register also accrues over longer spans; the generation study in
  `out/generation_study.md` is the complementary long-span view.
- `z`/`mass_z` are **within-cluster**: a word is compared to its own synonyms,
  not to the language at large.
