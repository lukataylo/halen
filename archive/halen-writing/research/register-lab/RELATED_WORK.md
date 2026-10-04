# Related work: is the register-lab thesis consistent with the literature and the prompt-engineering field?

This corroborates (or challenges) the five claims in [`FINDINGS.md`](FINDINGS.md)
against three bodies of evidence, gathered by separate research passes:
peer-reviewed papers, first-party / practitioner prompt-engineering guidance, and
the prompt-library ecosystem. Every source below was fetched and verified; nothing
is cited from memory.

**Bottom line.** Claims 1, 2, 4, 5 are well-supported by primary docs and
peer-reviewed work. The "instruction-tuning flattens register" sub-claim is
directly supported by a peer-reviewed result. **Claim 3 (slang is a weak lever;
base models read it literally) is the one finding with no prior source making that
*exact* point — but it is strongly corroborated by a separate, robust literature
showing LLMs default to literal readings of idioms/slang.** So claim 3 is best
presented as our contribution, consistent with (not contradicted by) the field.

---

## Claim 1 — word choice / phrasing steers output register

Supported by first-party docs and practitioner consensus (this is treated as
established, not controversial):

- **Anthropic, Claude prompt-engineering docs** — *"Setting a role in the system
  prompt focuses Claude's behavior and tone"*; *"Examples are one of the most
  reliable ways to steer Claude's output format, tone, and structure"*; and most
  on-point, *"the formatting style used in your prompt may influence Claude's
  response style… try matching your prompt style to your desired output style."*
  https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/system-prompts
- **OpenAI, prompt guidance** — *"Personality controls how the assistant sounds:
  tone, warmth, directness, formality, humor, empathy, and level of polish."*
  https://developers.openai.com/api/docs/guides/prompt-guidance
- **Google, Prompt Engineering whitepaper (Lee Boonstra, 2024)** — role prompting
  *"frames the model's output style and voice… adds a layer of specificity and
  personality."*
- **Simon Willison** (practitioner commentary, not a controlled study) — the
  "vibe"/phrasing of a prompt materially changes perceived model behaviour.
  https://simonwillison.net/tags/system-prompts/

## Claim 2 — formal / technical / institutional words are the strongest, cleanest levers

The controllable-generation literature shows attribute/lexical control works and
that **formality is among the cleanest controllable axes** — which is the
mechanism behind claim 2 (it supports the *direction*; no paper benchmarks
"institutional words beat other word classes" head-to-head, so that comparison is
our contribution):

- **PPLM — Plug and Play Language Models** (Dathathri et al., ICLR 2020,
  arXiv:1912.02164) — a *user-specified bag of words* is enough to steer topic/
  register. SUPPORTS.
- **GeDi** (Krause et al., Findings of EMNLP 2021, arXiv:2009.06367) — control
  codes + word-embedding topic cues steer reliably and generalize. SUPPORTS.
- **FUDGE** (Yang & Klein, NAACL 2021, arXiv:2104.05218) — formality and topic
  among the most cleanly decode-time-controllable attributes. SUPPORTS.
- **GYAFC** (Rao & Tetreault, NAACL 2018, arXiv:1803.06535) — establishes
  formality as a well-defined, learnable register dimension. SUPPORTS.
- **Survey of Controllable Text Generation** (Zhang et al., ACM CSUR,
  arXiv:2201.05337) and **Text Style Transfer overview** (arXiv:2407.14822) —
  NUANCE: lexical/attribute control is effective but content-preservation and
  lexical disentanglement are imperfect, i.e. levers are strong, not perfectly clean.

## Claim 3 — slang is a weak, treacherous lever; base models read it literally

No prior source states this exact thesis, but a robust literature shows the
literal-default bias it rests on (our register-lab observation `dough`→pastry,
`fire`→arson is a fresh data point consistent with all of these):

- **Knowledge of Slang in LLMs** (Sun et al., NAACL 2024, arXiv:2404.02323) —
  out-of-the-box models handle slang unreliably; fine-tuning needed. SUPPORTS.
- **Tug-of-war between idioms' figurative and literal interpretations** (Oh et al.,
  arXiv:2506.01723) — mechanistically, the literal reading must be *actively
  suppressed* to get the figurative one. SUPPORTS (mechanism).
- **Rolling the DICE on Idiomaticity** (Mi et al., arXiv:2410.16069) — systematic
  bias toward literal/compositional meaning. SUPPORTS.
- **Fig-QA** (Liu et al., NAACL 2022) — figurative interpretation weakest in the
  zero/few-shot setting closest to a base model. SUPPORTS.
- **SlangDIT** (Liang et al., arXiv:2505.14181) — concrete literal misreadings of
  slang; correct sense needs explicit reasoning. SUPPORTS.
- **Figurative language as humans do?** (Bollepally et al., arXiv:2601.09041) —
  NUANCE: the slang/idiom gap persists even after instruction tuning (largest on
  idioms and Gen-Z slang), so slang is a weak lever across the board, worst in
  base models.

## Claim 4 — GPT-2's WebText is Reddit-derived (verbatim primary source)

- **Language Models are Unsupervised Multitask Learners** (Radford et al., OpenAI
  2019), §2.1, quoted verbatim from OpenAI's PDF: *"we scraped all outbound links
  from Reddit, a social media platform, which received at least 3 karma… The
  resulting dataset, WebText, contains the text subset of these 45 million links."*
  CONFIRMED.

## Claim 5 — models leak demographic associations from training data

- **Bias in LLMs: Origin, Evaluation, and Mitigation** (arXiv:2411.10915) — models
  inherit and reproduce demographic stereotypes from training data. SUPPORTS.
- **Gender Bias in LLMs** (Apple ML Research) — LLM occupational gender rankings
  track *perceived* stereotypes more than real statistics. SUPPORTS.
  (Our `Yo`→kobe/kendrick/rappers proper-noun leakage is the same phenomenon.)

## Sub-claim — instruction-tuning / RLHF flattens register

- **Understanding the Effects of RLHF on LLM Generalisation and Diversity** (Kirk
  et al., 2023, arXiv:2310.06452) — *"RLHF significantly reduces output diversity
  compared to SFT across a variety of measures."* SUPPORTS.
- **Mysteries of Mode Collapse** (Janus, LessWrong 2022) and **Attributing Mode
  Collapse in Fine-Tuning** (OpenReview 3pDMYjpOxk) — corroborating. SUPPORTS.

---

## Does the prompt-library ecosystem corroborate the thesis?

Audited 22 prompt-library / marketplace / guide sites. **~13 STRONG, ~7 PARTIAL,
1 NONE (deprecated ShareGPT) — none contradict the finding.** The near-universal
lever is exactly what the thesis describes: persona/role framing ("act as / you
are a…"), explicit tone/style words, and audience framing ("write for a CTO / a
Hacker News reader / a high-schooler").

| Site | Consistency | Evidence |
|---|---|---|
| Anthropic Prompt Library / docs | STRONG | "match your prompt style to your desired output style"; "removing markdown from your prompt can reduce markdown in the output" |
| OpenAI examples / cookbook | STRONG | "You are a laconic assistant. You reply with brief, to-the-point answers…" |
| Google Gemini API — prompting strategies | STRONG | template "Tone: [Formal/Casual/Technical]" |
| learnprompting.org | STRONG | teaches roles to control "style, tone, or depth" |
| Awesome ChatGPT Prompts / prompts.chat | STRONG | nearly every entry is "I want you to act as…" |
| AIPRM | STRONG | "20 pre-built Tones and 19 pre-built Writing Styles" (academic, journalistic…) |
| PromptHero, FlowGPT, Snack Prompt, PromptDen, The Prompt Index | STRONG | persona + tone + vocabulary steering throughout |
| PromptPerfect (Jina) | STRONG | optimizer "adds context about tone, format, audience"; user "select[s] tone style" |
| jujumilk3/leaked-system-prompts | STRONG | production prompts ship as `…-output-style-default` / `-explanatory` / `-learning` |
| promptingguide.ai (DAIR), DAIR repo, God of Prompt, PromptFolder, Latitude, Microsoft Copilot gallery, PromptBase | PARTIAL | steer via structured *instructions/format* — one level up from single-word register; corroborates direction, not the word-level mechanism |
| ShareGPT | NONE | deprecated; out of scope, not contradictory |

**Telling detail consistent with claim 2:** vendor templates and pro tools
foreground *formal/technical* persona+tone slots ("academic", "journalistic",
"Formal/Technical", "professional, data-driven tone"), while slang/Reddit-register
prompting is mostly a hobbyist/roleplay phenomenon (FlowGPT, Reddit) — matching
the finding that formal words are the reliable lever and slang is the fringe one.

### ToS / policy notes
- `awesome-chatgpt-prompts` / `prompts.chat` are permissively licensed (MIT/CC0).
- God of Prompt bars repackaging its catalog into a competing prompt library.
- The leaked-system-prompts repos host third-party proprietary prompts —
  evidentially useful but legally sensitive to reuse.
- Several marketplaces (PromptHero, FlowGPT, Snack Prompt, PromptDen) return 403 to
  automated fetching and Microsoft Copilot gates prompt text behind sign-in; those
  rows were verified via homepages / raw data files / secondary sources.

---

## How this shaped the Prompt Polish plugin

The plugin's mode instructions deliberately use the levers the evidence says work:
explicit role ("You are a prompt engineer"), explicit format/length/audience, and
register-marking word choice for tone — and it leans on *formal/precise* word
swaps (the reliable lever, claim 2) rather than slang (the weak lever, claim 3).
