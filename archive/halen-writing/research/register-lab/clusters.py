"""The experiment design: *synonym clusters* and *carrier templates*.

A synonym cluster is a set of words/phrases that share a denotation (they mean
roughly the same thing) but differ in register connotation. Swapping one for
another inside an otherwise-identical prompt isolates the single variable we
care about: word choice.

Each cluster names the slot ("variants"), and a short human note on what each
variant is expected to evoke. The notes are *not* used in scoring — they are
there so a reader can sanity-check the data against intuition.

Carrier templates contain a `{w}` slot. We keep the carrier neutral so the
swapped word is the dominant register signal. Each cluster lists the carriers
that read grammatically with its variants.
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class Cluster:
    name: str
    gloss: str                       # the shared denotation
    variants: list[str]              # the words under test
    carriers: list[str]              # templates with a {w} slot
    notes: dict[str, str] = field(default_factory=dict)


# Neutral carriers reused across several clusters.
OPINION_CARRIERS = [
    "My {w} on the new remote-work policy is that",
    "Someone asked what I thought, and {w}, the situation is",
]
GREETING_CARRIERS = [
    "{w}. I wanted to talk about the budget for next quarter.",
    "{w}, so I've been looking into the climate data and",
]
DESCRIBE_GOOD_CARRIERS = [
    "I tried the new restaurant downtown. Honestly it was {w}.",
    "We finished the project and the result is {w}.",
]
REQUEST_CARRIERS = [
    "I need you to {w} the quarterly numbers before Friday.",
    "Can you {w} this issue with the login page?",
]
PEOPLE_CARRIERS = [
    "A lot of {w} have been asking about the schedule, so",
    "I want to thank all the {w} who showed up today.",
]


CLUSTERS: list[Cluster] = [
    Cluster(
        name="greeting",
        gloss="an opening salutation",
        variants=["Hello", "Hi", "Hey", "Yo", "Greetings", "Dear Sir or Madam"],
        carriers=GREETING_CARRIERS,
        notes={
            "Hey": "casual/Reddit", "Yo": "Gen-Z / street",
            "Greetings": "stiff/formal", "Dear Sir or Madam": "legal/formal letter",
        },
    ),
    Cluster(
        name="opinion_noun",
        gloss="a stated personal view",
        variants=["opinion", "take", "two cents", "hot take", "assessment", "position"],
        carriers=OPINION_CARRIERS,
        notes={
            "take": "casual/Reddit", "hot take": "Reddit/Twitter",
            "two cents": "casual idiom", "assessment": "academic/corporate",
            "position": "formal/legal",
        },
    ),
    Cluster(
        name="good_adj",
        gloss="positive evaluation",
        variants=["good", "great", "excellent", "awesome", "fire", "superb", "decent"],
        carriers=DESCRIBE_GOOD_CARRIERS,
        notes={
            "awesome": "casual", "fire": "Gen-Z slang",
            "superb": "formal/marketing", "excellent": "formal",
        },
    ),
    Cluster(
        name="investigate_verb",
        gloss="to examine something",
        variants=["investigate", "look into", "dig into", "check out", "probe", "audit"],
        carriers=REQUEST_CARRIERS,
        notes={
            "dig into": "casual", "check out": "casual",
            "audit": "corporate/legal", "probe": "journalistic/formal",
        },
    ),
    Cluster(
        name="people_noun",
        gloss="a group of persons",
        variants=["people", "folks", "guys", "individuals", "stakeholders", "everyone"],
        carriers=PEOPLE_CARRIERS,
        notes={
            "folks": "casual/Reddit", "guys": "casual",
            "individuals": "formal/academic", "stakeholders": "corporate",
        },
    ),
    Cluster(
        name="discuss_verb",
        gloss="to talk about",
        variants=["discuss", "talk about", "chat about", "touch base on", "deliberate on"],
        carriers=[
            "Dear team, I wanted to {w} the results from last week.",
            "Let's {w} the plan before we make any decisions.",
        ],
        notes={
            "chat about": "casual", "touch base on": "corporate",
            "deliberate on": "formal/legal",
        },
    ),
    Cluster(
        name="intensifier",
        gloss="degree amplifier",
        variants=["very", "really", "extremely", "super", "incredibly", "hella"],
        carriers=[
            "The new update is {w} important, and the reason is",
            "I'm {w} confident about the direction we're taking because",
        ],
        notes={
            "super": "casual", "hella": "Gen-Z/West-coast slang",
            "extremely": "formal", "incredibly": "marketing",
        },
    ),
    Cluster(
        name="money_noun",
        gloss="financial resources",
        variants=["money", "funds", "cash", "capital", "bucks", "dough"],
        carriers=[
            "We need to figure out where the {w} is going to come from, so",
            "The team is worried about {w}, and here's my plan:",
        ],
        notes={
            "cash": "casual", "bucks": "casual", "dough": "slang",
            "capital": "corporate/finance", "funds": "formal",
        },
    ),
]


def total_runs(samples_per_variant: int) -> int:
    return sum(len(c.variants) * len(c.carriers) for c in CLUSTERS) * samples_per_variant
