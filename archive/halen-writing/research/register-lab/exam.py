"""The generation study: run every synonym cluster through the model, sample
full continuations, and score them.

This is the "what you'd actually read" view. Its register *labels* are noisy on
a small base model (the lexicon markers barely appear in 60 tokens), so the
authoritative word->register dictionary is built by `mechanism.py` from the
next-token distribution instead. The value here is the example continuations and
the raw audit trail.

Usage:
    python3 exam.py [--model gpt2] [--samples 4] [--tokens 40] [--quick]

Outputs (in ./out):
    raw.json             every prompt, completion, and score (the audit trail)
    generation_study.md  per-cluster sampled continuations + example outputs
"""

from __future__ import annotations

import argparse
import json
import re
import statistics as stats
import time
from pathlib import Path

from clusters import CLUSTERS, Cluster
from lexicons import ALL_KEYS, REGISTER_KEYS, score_text
from model import LM

OUT = Path(__file__).parent / "out"
OUT.mkdir(exist_ok=True)

# Pretty labels for the register dimensions.
REG_LABEL = {
    "reg:reddit_casual": "Reddit / casual",
    "reg:academic": "academic",
    "reg:corporate": "corporate",
    "reg:genz_slang": "Gen-Z slang",
    "reg:legal_formal": "legal / formal",
    "reg:marketing_hype": "marketing hype",
    "reg:technical": "technical",
}


def mean_signature(texts: list[str]) -> dict[str, float]:
    sigs = [score_text(t) for t in texts if t.strip()]
    if not sigs:
        return {k: 0.0 for k in ALL_KEYS}
    return {k: stats.fmean(s[k] for s in sigs) for k in ALL_KEYS}


def zscores_within_cluster(
    per_variant: dict[str, dict[str, float]], keys: list[str]
) -> dict[str, dict[str, float]]:
    """For each key, z-score each variant against the cluster's variant
    distribution. Population std; zero std -> zero z (no signal to separate)."""
    out = {v: {} for v in per_variant}
    for k in keys:
        vals = [per_variant[v][k] for v in per_variant]
        mu = stats.fmean(vals)
        sd = stats.pstdev(vals)
        for v in per_variant:
            out[v][k] = 0.0 if sd == 0 else (per_variant[v][k] - mu) / sd
    return out


_WORDY = re.compile(r"[A-Za-z]")


def boosted_tokens(
    lm: LM, carriers: list[str], variants: list[str], topn: int = 10
) -> dict[str, list[str]]:
    """For each variant, which next tokens does it make likelier than the
    cluster average? Averages the next-token log-prob distribution across the
    cluster's carriers, then reports each variant's largest positive deltas vs
    the across-variant mean. This is the mechanism view: word choice reshaping
    P(next token) before any text is generated."""
    import torch

    # avg logprob vector per variant across carriers
    per_variant_lp = {}
    for v in variants:
        accum = None
        for carrier in carriers:
            prompt = carrier.replace("{w}", v)
            lp = lm.full_next_token_logprobs(prompt)
            accum = lp if accum is None else accum + lp
        per_variant_lp[v] = accum / len(carriers)

    baseline = torch.stack(list(per_variant_lp.values())).mean(dim=0)
    result = {}
    for v, lp in per_variant_lp.items():
        delta = lp - baseline
        idx = torch.topk(delta, 120).indices.tolist()
        vlow = v.lower()
        toks = []
        for tid in idx:
            raw = lm.token_text(tid)
            # Keep only whole-word tokens (GPT-2 marks word starts with a
            # leading space). Drop subword fragments ('etheless'), echoes of
            # the variant itself, and anything under 3 letters.
            if not raw.startswith(" "):
                continue
            t = raw.strip().lower()
            if len(t) < 3 or not t.isalpha():
                continue
            if t in vlow or vlow in t or t in toks:
                continue
            toks.append(t)
            if len(toks) >= topn:
                break
        result[v] = toks
    return result


def run_cluster(lm: LM, c: Cluster, samples: int, tokens: int) -> dict:
    print(f"  cluster '{c.name}' ({len(c.variants)} variants)...", flush=True)
    per_variant_sig: dict[str, dict[str, float]] = {}
    examples: dict[str, str] = {}
    raw: dict[str, list[dict]] = {}

    for v in c.variants:
        texts = []
        records = []
        for carrier in c.carriers:
            prompt = carrier.replace("{w}", v)
            comps = lm.generate(prompt, max_new_tokens=tokens, samples=samples)
            for comp in comps:
                texts.append(comp)
                records.append({"prompt": prompt, "completion": comp})
        per_variant_sig[v] = mean_signature(texts)
        raw[v] = records
        # representative example: longest non-trivial completion
        nonempty = sorted((t for t in texts if t.strip()), key=len, reverse=True)
        examples[v] = (nonempty[0] if nonempty else "").replace("\n", " ")[:240]

    z = zscores_within_cluster(per_variant_sig, REGISTER_KEYS)
    boosts = boosted_tokens(lm, c.carriers, c.variants)

    # dominant register pull per variant: register dim with max positive z
    dominant = {}
    for v in c.variants:
        best_key, best_z = max(z[v].items(), key=lambda kv: kv[1])
        # A genuine lean needs both a positive z and some actual marker density;
        # otherwise the argmax is just noise over all-zero dimensions.
        if best_z < 0.5 or per_variant_sig[v][best_key] == 0:
            dominant[v] = {"register": "neutral", "z": round(best_z, 2),
                           "raw_density": round(per_variant_sig[v][best_key], 2)}
        else:
            dominant[v] = {
                "register": REG_LABEL.get(best_key, best_key),
                "z": round(best_z, 2),
                "raw_density": round(per_variant_sig[v][best_key], 2),
            }

    return {
        "name": c.name,
        "gloss": c.gloss,
        "notes": c.notes,
        "signatures": per_variant_sig,
        "zscores": z,
        "dominant": dominant,
        "boosted_tokens": boosts,
        "examples": examples,
        "raw": raw,
    }


def write_report(results: list[dict], meta: dict):
    lines = ["# Register Lab — how one word steers the model\n"]
    lines.append(
        f"_Model: **{meta['model']}** · {meta['samples']} samples/variant · "
        f"{meta['tokens']} new tokens · {meta['n_completions']} completions · "
        f"{meta['runtime_s']}s_\n"
    )
    lines.append(
        "Each cluster below is a set of synonyms dropped into identical carrier "
        "sentences. The only thing that changes is the one word. The **z-score** "
        "is how far that word pushed the continuation toward a register, measured "
        "against the other synonyms in its own cluster (so it is a *relative* "
        "effect, controlling for the carrier).\n"
    )
    lines.append("## Headline\n")
    # global ranking of strongest shifters
    shifters = []
    for r in results:
        for v, d in r["dominant"].items():
            shifters.append((d["z"], v, r["name"], d["register"]))
    shifters.sort(reverse=True)
    lines.append("Strongest single-word register shifts observed:\n")
    lines.append("| word | cluster | pulls toward | z |")
    lines.append("|---|---|---|---|")
    for z, v, cl, reg in shifters[:12]:
        lines.append(f"| `{v}` | {cl} | **{reg}** | {z:+.2f} |")
    lines.append("")

    for r in results:
        lines.append(f"## Cluster: {r['name']} — _{r['gloss']}_\n")
        lines.append("| word | pulls toward | z | next-token boosts |")
        lines.append("|---|---|---|---|")
        ranked = sorted(
            r["dominant"].items(), key=lambda kv: kv[1]["z"], reverse=True
        )
        for v, d in ranked:
            toks = ", ".join(r["boosted_tokens"][v][:6])
            note = r["notes"].get(v, "")
            tag = f" _({note})_" if note else ""
            lines.append(f"| `{v}`{tag} | {d['register']} | {d['z']:+.2f} | {toks} |")
        lines.append("")
        # one example continuation for the top and bottom shifter
        top_v = ranked[0][0]
        lines.append(
            f"> example — `{top_v}` → \"{r['examples'][top_v]}\"\n"
        )

    (OUT / "generation_study.md").write_text("\n".join(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="gpt2")
    ap.add_argument("--samples", type=int, default=4)
    ap.add_argument("--tokens", type=int, default=40)
    ap.add_argument("--quick", action="store_true", help="2 samples, 24 tokens")
    args = ap.parse_args()
    if args.quick:
        args.samples, args.tokens = 2, 24

    t0 = time.time()
    print(f"loading {args.model} ...", flush=True)
    lm = LM(args.model)

    results = []
    n_completions = 0
    for c in CLUSTERS:
        r = run_cluster(lm, c, args.samples, args.tokens)
        results.append(r)
        n_completions += sum(len(v) for v in r["raw"].values())

    runtime = round(time.time() - t0, 1)
    meta = {
        "model": args.model,
        "samples": args.samples,
        "tokens": args.tokens,
        "n_completions": n_completions,
        "runtime_s": runtime,
    }

    (OUT / "raw.json").write_text(
        json.dumps({"meta": meta, "results": results}, indent=2)
    )
    write_report(results, meta)
    print(f"done in {runtime}s — {n_completions} completions. See ./out/", flush=True)
    print("note: register *labels* here are noisy at small scale; the "
          "authoritative dictionary comes from mechanism.py.", flush=True)


if __name__ == "__main__":
    main()
