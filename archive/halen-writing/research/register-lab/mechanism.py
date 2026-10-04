"""The mechanism study — the authoritative analysis.

Where `exam.py` samples whole continuations and counts register markers in them
(noisy on a small base model), this measures the effect at its source: the
**next-token probability distribution**. For each prompt it reads, directly off
the softmax, how much probability the model places on each register's marker
tokens *as the very next token*. That signal is dense (every register gets a
real number from one forward pass) instead of sparse (waiting for a marker to
randomly appear in 60 sampled tokens), so the register labels it produces are
far more stable.

It is also fast: no autoregressive generation, just one forward pass per
(variant, carrier).

Outputs (in ./out): mechanism.json, REPORT.md, DICTIONARY.md, dictionary.json.
"""

from __future__ import annotations

import json
import re
import statistics as stats
import time
from pathlib import Path

import torch

from clusters import CLUSTERS
from lexicons import REGISTERS
from model import LM

# Single-token marker set per register, for classifying a word's distinctive
# next-token fingerprint. We match the *first word* of each marker so multi-word
# markers ("circle back") still contribute their head ("circle").
REG_WORDS = {
    reg: {mk.split()[0].lower() for mk in markers}
    for reg, markers in REGISTERS.items()
}

OUT = Path(__file__).parent / "out"
OUT.mkdir(exist_ok=True)

REG_LABEL = {
    "reddit_casual": "Reddit / casual",
    "academic": "academic",
    "corporate": "corporate",
    "genz_slang": "Gen-Z slang",
    "legal_formal": "legal / formal",
    "marketing_hype": "marketing hype",
    "technical": "technical",
}
_WORDY = re.compile(r"[A-Za-z]")


def build_register_token_ids(lm: LM) -> dict[str, list[int]]:
    """Map each register to the vocab token-ids that *begin* its marker words.

    Next-token prediction emits a word's first token, so we take the leading-
    space encoding of each marker (GPT-2's word-onset form) and keep its first
    token id. Multi-word markers contribute their first word's onset token."""
    out: dict[str, list[int]] = {}
    for reg, markers in REGISTERS.items():
        ids: set[int] = set()
        for mk in markers:
            first = mk.split()[0]
            for form in (" " + first, " " + first.capitalize()):
                enc = lm.tok.encode(form)
                if enc:
                    ids.add(enc[0])
        out[reg] = sorted(ids)
    return out


def mass_from_lp(lp: "torch.Tensor", reg_ids: dict[str, list[int]]) -> dict[str, float]:
    """Probability mass on each register's onset tokens, from a cached
    next-token log-prob vector (probs = exp(lp))."""
    probs = lp.exp()
    return {reg: float(probs[tids].sum()) for reg, tids in reg_ids.items()}


def boosted_from_lp(lm: LM, variant: str, variant_lp: "torch.Tensor",
                    baseline_lp: "torch.Tensor", topn=20):
    """Top next-tokens this variant promotes vs the cluster's average variant,
    from cached log-prob vectors. Echoes of the variant word itself are dropped
    so a word can't 'predict itself'."""
    delta = variant_lp - baseline_lp
    vlow = variant.lower()
    out: list[str] = []
    for tid in torch.topk(delta, 200).indices.tolist():
        raw = lm.token_text(tid)
        if not raw.startswith(" "):   # word-onset tokens only (byte-BPE space)
            continue
        t = raw.strip().lower()
        if len(t) < 3 or not t.isalpha() or t in out:
            continue
        if t in vlow or vlow in t:   # drop self-echo ('capital'->capital)
            continue
        out.append(t)
        if len(out) >= topn:
            break
    return out


def classify_fingerprint(tokens: list[str]) -> tuple[str, int]:
    """Label a word by its distinctive next-token fingerprint: how many of its
    boosted tokens fall into each register's marker vocabulary. This ties the
    label to the *displayed evidence* (the tokens the word actually promotes),
    which is far more reliable than counting markers in sparse generations or
    measuring marker-onset mass (which collides with high-frequency tokens).

    Returns (register, hits). Needs >=2 hits to claim a register; otherwise the
    fingerprint is literal/idiosyncratic (e.g. slang triggering its literal
    sense in a base model) and we call it 'neutral'."""
    counts = {reg: sum(1 for t in tokens if t in words)
              for reg, words in REG_WORDS.items()}
    reg, hits = max(counts.items(), key=lambda kv: kv[1])
    if hits < 2:
        return "neutral", hits
    return REG_LABEL[reg], hits


def zscores(per_variant: dict[str, dict[str, float]]):
    regs = list(next(iter(per_variant.values())).keys())
    out = {v: {} for v in per_variant}
    for reg in regs:
        vals = [per_variant[v][reg] for v in per_variant]
        mu, sd = stats.fmean(vals), stats.pstdev(vals)
        for v in per_variant:
            out[v][reg] = 0.0 if sd == 0 else (per_variant[v][reg] - mu) / sd
    return out


@torch.no_grad()
def run(model_name: str = "gpt2", dtype: str = "float32"):
    t0 = time.time()
    print(f"loading {model_name} ({dtype}) ...", flush=True)
    lm = LM(model_name, dtype=dtype)
    reg_ids = build_register_token_ids(lm)

    results = []
    for c in CLUSTERS:
        print(f"  {c.name} ...", flush=True)
        prompts = {v: [cr.replace("{w}", v) for cr in c.carriers] for v in c.variants}

        # One forward pass per (variant, carrier); cache the next-token log-prob
        # vector. Everything else (register mass, fingerprints) is derived from
        # the cache, so a 3B model stays tractable on CPU.
        carrier_lp = {v: [lm.full_next_token_logprobs(p) for p in prompts[v]]
                      for v in c.variants}
        avg_lp = {v: torch.stack(carrier_lp[v]).mean(dim=0) for v in c.variants}
        baseline_lp = torch.stack(list(avg_lp.values())).mean(dim=0)

        mass = {}
        for v in c.variants:
            per_carrier = [mass_from_lp(lp, reg_ids) for lp in carrier_lp[v]]
            mass[v] = {reg: stats.fmean(d[reg] for d in per_carrier) for reg in reg_ids}
        z = zscores(mass)

        boosts = {v: boosted_from_lp(lm, v, avg_lp[v], baseline_lp) for v in c.variants}

        dominant = {}
        for v in c.variants:
            reg, hits = classify_fingerprint(boosts[v])
            key = next((k for k, lbl in REG_LABEL.items() if lbl == reg), None)
            dominant[v] = {
                "register": reg,
                "fingerprint_hits": hits,
                "mass_z": round(z[v][key], 2) if key else 0.0,
            }
        results.append({
            "name": c.name, "gloss": c.gloss, "notes": c.notes,
            "mass": mass, "z": z, "dominant": dominant, "boosts": boosts,
        })

    meta = {"model": lm.name, "method": "next-token register fingerprint",
            "runtime_s": round(time.time() - t0, 1)}
    # gpt2 keeps the canonical filenames; other models get a slug suffix so
    # runs can be compared side by side without overwriting.
    slug = "" if model_name == "gpt2" else "." + model_name.split("/")[-1].lower()
    (OUT / f"mechanism{slug}.json").write_text(
        json.dumps({"meta": meta, "results": results}, indent=2))
    write_report(results, meta, slug)
    write_dictionary(results, meta, slug)
    print(f"done in {meta['runtime_s']}s. See ./out/DICTIONARY{slug}.md", flush=True)


def write_report(results, meta, slug=""):
    L = ["# Register Lab — the mechanism: word choice reshapes P(next token)\n"]
    L.append(f"_Model: **{meta['model']}** · method: {meta['method']} · {meta['runtime_s']}s_\n")
    L.append(
        "Each synonym is dropped into identical carrier sentences; the only "
        "variable is the one word. We then read the model's **next-token "
        "distribution** and rank the tokens this word makes likelier than its "
        "synonyms do — its *register fingerprint*. The label is assigned by how "
        "many of those distinctive tokens fall into a register's vocabulary "
        "(`hits`); `mass_z` is a second, distributional check (how much next-"
        "token probability mass the word puts on that register's markers, in "
        "std-devs above its synonyms).\n")

    shifters = []
    for r in results:
        for v, d in r["dominant"].items():
            if d["register"] != "neutral":
                shifters.append((d["fingerprint_hits"], d["mass_z"], v,
                                 r["name"], d["register"]))
    shifters.sort(reverse=True)
    L.append("## Clearest single-word register fingerprints\n")
    L.append("| word | cluster | pulls toward | fingerprint hits | mass_z |\n|---|---|---|---|---|")
    for hits, mz, v, cl, reg in shifters[:15]:
        L.append(f"| `{v}` | {cl} | **{reg}** | {hits} | {mz:+.2f} |")
    L.append("")

    for r in results:
        L.append(f"## {r['name']} — _{r['gloss']}_\n")
        L.append("| word | pulls toward | hits | makes likelier (next token) |\n|---|---|---|---|")
        ranked = sorted(r["dominant"].items(),
                        key=lambda kv: (kv[1]["fingerprint_hits"], kv[1]["mass_z"]),
                        reverse=True)
        for v, d in ranked:
            note = r["notes"].get(v, "")
            tag = f" _({note})_" if note else ""
            toks = ", ".join(r["boosts"][v][:6])
            L.append(f"| `{v}`{tag} | {d['register']} | {d['fingerprint_hits']} | {toks} |")
        L.append("")
    (OUT / f"REPORT{slug}.md").write_text("\n".join(L))


def write_dictionary(results, meta, slug=""):
    entries = []
    for r in results:
        for v, d in r["dominant"].items():
            entries.append({
                "word": v, "means": r["gloss"], "cluster": r["name"],
                "evokes": d["register"], "fingerprint_hits": d["fingerprint_hits"],
                "mass_z": d["mass_z"], "makes_likelier": r["boosts"][v],
                "human_note": r["notes"].get(v, ""),
            })
    (OUT / f"dictionary{slug}.json").write_text(json.dumps(entries, indent=2))

    by_reg: dict[str, list[dict]] = {}
    for e in entries:
        by_reg.setdefault(e["evokes"], []).append(e)

    L = ["# The LLM Word→Register Dictionary\n"]
    L.append(
        f"_Derived empirically from **{meta['model']}** via {meta['method']}. "
        "Each word is grouped under the register its distinctive next-token "
        "fingerprint matches. `hits` = how many of the word's boosted tokens are "
        "register markers; `mass_z` = next-token probability mass on that "
        "register (std-devs above the word's synonyms)._\n")
    L.append(
        "**How to use it.** Pick a meaning, then choose the synonym whose "
        "register you want. *\"Give me your hot take\"* and *\"give me your "
        "assessment\"* are the same request — but the first word tilts the "
        "model's next-token distribution toward casual/forum language and the "
        "second toward formal/analytic language, and that tilt compounds across "
        "every following token into a whole different answer.\n")
    L.append(
        "_`neutral` = the word's strongest associations were literal or "
        "idiosyncratic rather than register-marking — notably slang whose "
        "literal sense dominates in a base model (`dough`→baking, `fire`→arson, "
        "`bucks`→buffalo)._\n")

    order = sorted(by_reg, key=lambda reg: (reg == "neutral",
                   -sum(e["fingerprint_hits"] for e in by_reg[reg])))
    for reg in order:
        items = sorted(by_reg[reg],
                       key=lambda e: (e["fingerprint_hits"], e["mass_z"]),
                       reverse=True)
        L.append(f"## Pulls toward: {reg}\n")
        L.append("| word | meaning | hits | mass_z | makes likelier |\n|---|---|---|---|---|")
        for e in items:
            toks = ", ".join(e["makes_likelier"][:6])
            L.append(f"| **{e['word']}** | {e['means']} | {e['fingerprint_hits']} | {e['mass_z']:+.2f} | {toks} |")
        L.append("")
    (OUT / f"DICTIONARY{slug}.md").write_text("\n".join(L))


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="gpt2")
    ap.add_argument("--dtype", default="float32",
                    choices=["float32", "bfloat16", "float16"])
    args = ap.parse_args()
    run(args.model, args.dtype)
