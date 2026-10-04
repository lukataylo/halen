"""Register lexicons + structural metrics — the *measuring instrument*.

Everything the lab concludes rests on this file, so it is deliberately
transparent: each register is a flat, auditable word/phrase list, and each
structural metric is a plain function over tokens. Nothing here calls a model.

A "register" is a recognisable style of language tied to a social context:
the way people write on Reddit is not the way they write a legal brief. The
thesis under test is that swapping a single *register-marked* word in a prompt
tilts the model's continuation toward that word's home register. To measure the
tilt we score any text on how densely it hits each register's marker set.

Scores are reported as **hits per 100 words** so texts of different length stay
comparable.
"""

from __future__ import annotations

import re
from collections import Counter

# --- Register marker sets ---------------------------------------------------
# Markers are matched as whole words/phrases, case-insensitively. They are
# chosen to be *diagnostic* (rare outside their register) rather than exhaustive.

REGISTERS: dict[str, list[str]] = {
    "reddit_casual": [
        "honestly", "tbh", "imo", "imho", "ngl", "basically", "literally",
        "actually", "kinda", "sorta", "gonna", "wanna", "gotta", "yeah", "yep",
        "nah", "dude", "dudes", "guy", "guys", "folks", "stuff", "pretty much",
        "i mean", "like", "lol", "lmao", "haha", "dunno", "blah", "damn",
        "shit", "fuck", "fuckin", "fucking", "edit:", "downvote", "upvote",
        "op", "redditor", "subreddit", "thread", "100%", "for real", "fwiw",
    ],
    "academic": [
        "furthermore", "moreover", "hence", "thus", "therefore",
        "consequently", "hypothesis", "empirical", "methodology", "literature",
        "framework", "significant", "correlation", "variance", "et al",
        "respectively", "aforementioned", "notwithstanding", "insofar",
        "phenomenon", "paradigm", "theoretical", "analysis", "data suggest",
        "numerous", "considerable", "substantial", "unprecedented", "stringent",
        "polarized", "divisive",
    ],
    "corporate": [
        "leverage", "synergy", "synergies", "stakeholder", "stakeholders",
        "deliverable", "deliverables", "bandwidth", "circle back", "actionable",
        "alignment", "roadmap", "kpi", "kpis", "roi", "touch base",
        "low-hanging", "ecosystem", "scalable", "best practice", "value-add",
        "move the needle", "drill down", "going forward", "core competency",
        "policymakers", "regulators", "constituents", "governments", "ngos",
        "implementation", "organisations", "organizations", "investment",
        "investments", "liquidity", "dividend", "fiscal", "infrastructure",
        "redevelopment", "capital", "audit", "auditor", "auditors", "certify",
        "certification", "compliance", "inspect",
    ],
    "genz_slang": [
        "fr", "ngl", "vibe", "vibes", "slay", "lowkey", "highkey", "based",
        "bro", "bruh", "fam", "sus", "cap", "no cap", "bet", "rizz", "mid",
        "cooked", "goated", "ate", "ick", "deadass", "fire", "slaps", "valid",
        "iykyk", "bussin",
    ],
    "legal_formal": [
        "shall", "hereby", "herein", "hereof", "thereof", "thereto",
        "pursuant", "aforesaid", "whereas", "notwithstanding", "indemnify",
        "liability", "covenant", "provision", "stipulate", "the party",
        "the parties", "in witness whereof", "for the avoidance of doubt",
        "subject to", "in accordance with", "plaintiff", "plaintiffs",
        "defendant", "defendants", "attorney", "counsel", "litigation",
        "statute", "judicial", "ruling", "unlawfully", "ministers",
        "parliamentary", "directive", "directives",
    ],
    "marketing_hype": [
        "amazing", "incredible", "revolutionary", "game-changing", "unlock",
        "transform", "transformative", "elevate", "supercharge", "effortless",
        "seamless", "stunning", "ultimate", "exclusive", "limited",
        "introducing", "world-class", "next-level", "must-have", "love",
        "obsessed", "empowering", "groundbreaking", "unparalleled", "profound",
        "wonderful", "excellence", "featuring",
    ],
    "technical": [
        "function", "parameter", "implementation", "configure", "instantiate",
        "endpoint", "latency", "throughput", "buffer", "thread", "async",
        "deprecated", "compile", "runtime", "dependency", "interface", "schema",
        "boolean", "null", "exception", "stack trace", "syntax",
    ],
}

# --- Structural / stylistic metrics ----------------------------------------

CONTRACTIONS = re.compile(
    r"\b(?:i'm|you're|we're|they're|he's|she's|it's|that's|don't|doesn't|"
    r"didn't|can't|won't|isn't|aren't|wasn't|weren't|i've|you've|we've|"
    r"i'd|you'd|i'll|you'll|we'll|there's|here's|let's|gonna|wanna|gotta)\b",
    re.IGNORECASE,
)
HEDGES = re.compile(
    r"\b(?:maybe|perhaps|possibly|probably|i think|i guess|sort of|kind of|"
    r"somewhat|arguably|it seems|might|could be|in my opinion|i suppose)\b",
    re.IGNORECASE,
)
FIRST_PERSON = re.compile(r"\b(?:i|me|my|mine|we|us|our|ours)\b", re.IGNORECASE)
SECOND_PERSON = re.compile(r"\b(?:you|your|yours)\b", re.IGNORECASE)
EMOJI = re.compile(
    "[" "\U0001f300-\U0001faff" "\U00002600-\U000027bf" "\U0001f000-\U0001f0ff" "]",
    flags=re.UNICODE,
)
WORD = re.compile(r"[A-Za-z']+")

# Registers whose markers are multi-word need phrase scanning over the raw text;
# single tokens are counted over the word list. We handle both uniformly by
# substring-scanning the lowercased, space-normalised text for each marker with
# word boundaries.


def _norm(text: str) -> str:
    return re.sub(r"\s+", " ", text.lower()).strip()


def _count_marker(text_norm: str, marker: str) -> int:
    # Whole-word/phrase match. Markers may contain spaces or punctuation
    # (e.g. "edit:", "et al"), so build a boundary-aware pattern per marker.
    m = re.escape(marker.lower())
    if marker[0].isalnum():
        m = r"\b" + m
    if marker[-1].isalnum():
        m = m + r"\b"
    return len(re.findall(m, text_norm))


def register_hits(text: str) -> dict[str, int]:
    """Raw marker counts per register for one text."""
    tn = _norm(text)
    return {
        reg: sum(_count_marker(tn, mk) for mk in markers)
        for reg, markers in REGISTERS.items()
    }


def words(text: str) -> list[str]:
    return WORD.findall(text.lower())


def structural_metrics(text: str) -> dict[str, float]:
    """Style metrics that are *register-bearing* but not lexicon-based.

    All rates are per 100 words except ratios (0-1) and lengths.
    """
    w = words(text)
    n = max(len(w), 1)
    sentences = [s for s in re.split(r"[.!?]+", text) if s.strip()]
    return {
        "contractions": 100 * len(CONTRACTIONS.findall(text)) / n,
        "hedging": 100 * len(HEDGES.findall(text)) / n,
        "first_person": 100 * len(FIRST_PERSON.findall(text)) / n,
        "second_person": 100 * len(SECOND_PERSON.findall(text)) / n,
        "emoji": 100 * len(EMOJI.findall(text)) / n,
        "exclamations": 100 * text.count("!") / n,
        "questions": 100 * text.count("?") / n,
        "avg_word_len": sum(len(x) for x in w) / n,
        "type_token_ratio": len(set(w)) / n,
        "avg_sentence_len": (n / len(sentences)) if sentences else float(n),
    }


def score_text(text: str) -> dict[str, float]:
    """Full register signature of a text: per-register marker density (per 100
    words) plus structural metrics. This is the vector everything aggregates."""
    w = words(text)
    n = max(len(w), 1)
    sig = {f"reg:{reg}": 100 * hits / n for reg, hits in register_hits(text).items()}
    sig.update({f"st:{k}": v for k, v in structural_metrics(text).items()})
    return sig


# Convenience: the canonical ordering used in reports.
REGISTER_KEYS = [f"reg:{r}" for r in REGISTERS]
STRUCT_KEYS = [
    "st:contractions", "st:hedging", "st:first_person", "st:second_person",
    "st:emoji", "st:exclamations", "st:questions", "st:avg_word_len",
    "st:type_token_ratio", "st:avg_sentence_len",
]
ALL_KEYS = REGISTER_KEYS + STRUCT_KEYS


def empty_signature() -> Counter:
    return Counter({k: 0.0 for k in ALL_KEYS})
