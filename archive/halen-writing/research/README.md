# research/

Standalone research tools and write-ups. Not part of the shipped Halen app.

- [`register-lab/`](register-lab/) — a tool for understanding how prompt word
  choice steers next-token prediction, and the empirical **word → register
  dictionary** it produces. See `register-lab/out/DICTIONARY.md` for the
  headline result, `register-lab/FINDINGS.md` for the written conclusion, and
  `register-lab/RELATED_WORK.md` for the literature/prompt-library cross-check.

The applied counterpart ships in the app as the **Prompt Polish** plugin
(`Sources/Halen/Features/PromptPolish/`, ⌃⌥P), which makes word-level edits to
prompts using these findings.
