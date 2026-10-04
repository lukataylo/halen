# Register Lab — how one word steers the model

_Model: **gpt2** · 6 samples/variant · 60 new tokens · 576 completions · 608.8s_

Each cluster below is a set of synonyms dropped into identical carrier sentences. The only thing that changes is the one word. The **z-score** is how far that word pushed the continuation toward a register, measured against the other synonyms in its own cluster (so it is a *relative* effect, controlling for the carrier).

## Headline

Strongest single-word register shifts observed:

| word | cluster | pulls toward | z |
|---|---|---|---|
| `probe` | investigate_verb | **corporate** | +2.24 |
| `opinion` | opinion_noun | **academic** | +2.24 |
| `money` | money_noun | **academic** | +2.24 |
| `hella` | intensifier | **technical** | +2.24 |
| `everyone` | people_noun | **corporate** | +2.24 |
| `dig into` | investigate_verb | **academic** | +2.24 |
| `Greetings` | greeting | **marketing hype** | +2.24 |
| `guys` | people_noun | **marketing hype** | +2.02 |
| `talk about` | discuss_verb | **marketing hype** | +2.00 |
| `really` | intensifier | **marketing hype** | +2.00 |
| `Yo` | greeting | **Reddit / casual** | +1.80 |
| `fire` | good_adj | **Reddit / casual** | +1.79 |

## Cluster: greeting — _an opening salutation_

| word | pulls toward | z | next-token boosts |
|---|---|---|---|
| `Greetings` _(stiff/formal)_ | marketing hype | +2.24 | flavoring, below, software, monthly, released, asset |
| `Yo` _(Gen-Z / street)_ | Reddit / casual | +1.80 | kobe, kendrick, rappers, lebron, kanye, tup |
| `Hello` | Gen-Z slang | +1.44 | satell, srf, synchronization, statically, conflic, dynamically |
| `Hey` _(casual/Reddit)_ | Gen-Z slang | +1.39 | trayvon, philly, yeah, whitney, blah, lebron |
| `Hi` | corporate | +1.15 | srf, tremend, practition, cryptoc, mathemat, princ |
| `Dear Sir or Madam` _(legal/formal letter)_ | academic | +1.04 | apologise, labour, ministers, fulfil, enqu, parliamentary |

> example — `Greetings` → "seeing how it's changed over time. In short – this was a big challenge for me to overcome but not before getting my hands dirty with all of our major statistical tools (in fact many months). First off we have some cool charts showing that t"

## Cluster: opinion_noun — _a stated personal view_

| word | pulls toward | z | next-token boosts |
|---|---|---|---|
| `opinion` | academic | +2.24 | divisive, strongest, polarized, passionately, mainly, unanimous |
| `two cents` _(casual idiom)_ | Gen-Z slang | +1.54 | macy, sold, rite, coupon, coupons, amtrak |
| `position` _(formal/legal)_ | Reddit / casual | +1.45 | directive, directives, relevant, specified, normative, delim |
| `hot take` _(Reddit/Twitter)_ | Gen-Z slang | +1.28 | dating, emails, celeb, hotter, heats, sexy |
| `take` _(casual/Reddit)_ | neutral | +0.00 | suppose, unintention, guiicon, teasp, accounts, consider |
| `assessment` _(academic/corporate)_ | neutral | +0.00 | oecd, favourable, mitigation, brexit, resettlement, sustained |

> example — `opinion` → "it gives you a chance to put your own hands behind them and start working for something less financially viable. The first thing I think of when talking about how good this technology might be in terms, are our companies' financials -- we'r"

## Cluster: good_adj — _positive evaluation_

| word | pulls toward | z | next-token boosts |
|---|---|---|---|
| `fire` _(Gen-Z slang)_ | Reddit / casual | +1.79 | extingu, arson, blaze, flames, combust, extinguished |
| `superb` _(formal/marketing)_ | marketing hype | +1.59 | highly, featuring, wonderful, excellence, pair, emin |
| `decent` | Gen-Z slang | +1.53 | but, nonetheless, nevertheless, however, mediocre, still |
| `awesome` _(casual)_ | marketing hype | +1.40 | volunte, srf, entreprene, tradem, carbohyd, tremend |
| `great` | Gen-Z slang | +0.90 | lyft, feedback, thank, integration, downloads, sharing |
| `good` | neutral | +0.00 | but, nevertheless, bye, recomm, tod, else |
| `excellent` _(formal)_ | neutral | +0.00 | highly, selection, service, customer, delivery, ingredients |

> example — `fire` → "The results are incredible!" One of those very few times I did not know what to expect, but when you have an amazing product with a lot going on inside it can be hard for many people even after they finish building your first prototype with"

## Cluster: investigate_verb — _to examine something_

| word | pulls toward | z | next-token boosts |
|---|---|---|---|
| `dig into` _(casual)_ | academic | +2.24 | krugman, digs, sack, gross, hungry, dre |
| `probe` _(journalistic/formal)_ | corporate | +2.24 | probing, mosqu, interrog, suspic, forcefully, penet |
| `investigate` | Reddit / casual | +1.26 | enqu, unlawfully, endeavour, contact, inform, exting |
| `audit` _(corporate/legal)_ | Reddit / casual | +0.62 | cert, certify, certification, inspect, certific, certificate |
| `look into` | Reddit / casual | +0.52 | syrians, ukrainians, latinos, krish, africans, sov |
| `check out` _(casual)_ | neutral | +0.00 | pione, earthqu, coupon, randomredditor, externaltoeva, thenitrome |

> example — `dig into` → ""The first quarter of 2012 was a good year for business in my opinion," he said. "We got hit by very strong commodity prices and we had some significant growth on our balance sheet." He called down his price target as low more than $10 per "

## Cluster: people_noun — _a group of persons_

| word | pulls toward | z | next-token boosts |
|---|---|---|---|
| `everyone` | corporate | +2.24 | gobl, tremend, spoilers, sweets, haha, conflic |
| `guys` _(casual)_ | marketing hype | +2.02 | dudes, dude, fuckin, yeah, gotta, shit |
| `folks` _(casual/Reddit)_ | neutral | +0.29 | check, tune, turns, here, enjoy, stay |
| `people` | neutral | +0.22 | peacefully, pray, tears, abortion, evacuate, forgive |
| `stakeholders` _(corporate)_ | neutral | +0.06 | ngos, policymakers, implementation, feder, governments, organisations |
| `individuals` _(formal/academic)_ | neutral | +0.00 | plaint, plaintiff, counsel, attorney, defendants, investigators |

> example — `everyone` → "I am truly grateful for your support, advice and help that you took with me throughout this journey!" The most interesting part of it was hearing from them about their parents' stories: they really were very excited when asked how things we"

## Cluster: discuss_verb — _to talk about_

| word | pulls toward | z | next-token boosts |
|---|---|---|---|
| `talk about` | marketing hype | +2.00 | obamacare, republicans, reagan, obama, nafta, president |
| `touch base on` _(corporate)_ | Reddit / casual | +0.86 | consumers, yet, forbes, rather, manufacturing, advertising |
| `deliberate on` _(formal/legal)_ | Reddit / casual | +0.65 | otherwise, reduce, removal, period, remove, instead |
| `discuss` | Reddit / casual | +0.50 | procedure, appendix, summarize, summarizes, suppose, considerations |
| `chat about` _(casual)_ | neutral | +0.00 | tremend, carbohyd, volunte, practition, teasp, councill |

> example — `talk about` → "I want to emphasize that this is a long-term strategy, and as you probably know by now there are several different kinds of approaches for doing it; but one important part -- what happens when somebody comes up with something new? And so ho"

## Cluster: intensifier — _degree amplifier_

| word | pulls toward | z | next-token boosts |
|---|---|---|---|
| `hella` _(Gen-Z/West-coast slang)_ | technical | +2.24 | dunno, goddamn, godd, fuckin, fuck, shit |
| `really` | marketing hype | +2.00 | learners, uptake, fragmentation, maybe, kind, parcels |
| `very` | academic | +1.40 | bilateral, reciprocal, tariff, bilingual, residential, unilateral |
| `super` _(casual)_ | Gen-Z slang | +0.62 | shirt, awesome, lol, haha, plus, tags |
| `incredibly` _(marketing)_ | Gen-Z slang | +0.62 | transformative, empowering, profound, groundbreaking, unparalleled, countless |
| `extremely` _(formal)_ | neutral | +0.00 | significant, numerous, strengthened, unprecedented, considerable, stringent |

> example — `hella` → "simple: SEO was a big problem in 2016 when it came to Google Search. The search giant just changed its design philosophy by creating an entirely separate interface for each of these elements—it now includes their entire capabilities (but no"

## Cluster: money_noun — _financial resources_

| word | pulls toward | z | next-token boosts |
|---|---|---|---|
| `money` | academic | +2.24 | transparency, scholarships, daca, scholarship, salary, medicare |
| `cash` _(casual)_ | Reddit / casual | +0.67 | gambling, payments, poker, liquidity, gamb, dividend |
| `funds` _(formal)_ | neutral | +0.28 | funding, cosponsors, nct, donations, fundraising, funded |
| `bucks` _(casual)_ | neutral | +0.04 | cowboy, buffalo, females, panther, whine, cow |
| `capital` _(corporate/finance)_ | neutral | +0.00 | cities, infrastructure, redevelopment, investment, metropolitan, investments |
| `dough` _(slang)_ | neutral | +0.00 | pastry, bake, baking, oven, bisc, gluten |

> example — `money` → "This week I will try to get the ball rolling on a potential deal for Chris Paul. The NBA wants him at least in exchange for an extension of his current contract (which expires after this season). He might be able win over some fans by playi"
