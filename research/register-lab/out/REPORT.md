# Register Lab — the mechanism: word choice reshapes P(next token)

_Model: **gpt2** · method: next-token register fingerprint · 46.9s_

Each synonym is dropped into identical carrier sentences; the only variable is the one word. We then read the model's **next-token distribution** and rank the tokens this word makes likelier than its synonyms do — its *register fingerprint*. The label is assigned by how many of those distinctive tokens fall into a register's vocabulary (`hits`); `mass_z` is a second, distributional check (how much next-token probability mass the word puts on that register's markers, in std-devs above its synonyms).

## Clearest single-word register fingerprints

| word | cluster | pulls toward | fingerprint hits | mass_z |
|---|---|---|---|---|
| `hella` | intensifier | **Reddit / casual** | 10 | +2.07 |
| `guys` | people_noun | **Reddit / casual** | 10 | +0.58 |
| `extremely` | intensifier | **academic** | 6 | +1.74 |
| `Hey` | greeting | **Reddit / casual** | 6 | +1.03 |
| `stakeholders` | people_noun | **corporate** | 6 | +0.89 |
| `incredibly` | intensifier | **marketing hype** | 6 | +0.13 |
| `capital` | money_noun | **corporate** | 4 | +1.91 |
| `individuals` | people_noun | **legal / formal** | 4 | -0.41 |
| `superb` | good_adj | **marketing hype** | 3 | +1.58 |
| `super` | intensifier | **Reddit / casual** | 3 | +0.20 |
| `Yo` | greeting | **Reddit / casual** | 3 | +0.11 |
| `audit` | investigate_verb | **corporate** | 3 | -0.15 |
| `position` | opinion_noun | **legal / formal** | 2 | +1.15 |
| `Dear Sir or Madam` | greeting | **legal / formal** | 2 | +0.74 |
| `everyone` | people_noun | **Reddit / casual** | 2 | +0.22 |

## greeting — _an opening salutation_

| word | pulls toward | hits | makes likelier (next token) |
|---|---|---|---|
| `Hey` _(casual/Reddit)_ | Reddit / casual | 6 | trayvon, philly, yeah, whitney, blah, lebron |
| `Yo` _(Gen-Z / street)_ | Reddit / casual | 3 | kobe, kendrick, rappers, lebron, kanye, tup |
| `Dear Sir or Madam` _(legal/formal letter)_ | legal / formal | 2 | apologise, labour, ministers, fulfil, enqu, parliamentary |
| `Hello` | neutral | 0 | satell, srf, synchronization, statically, conflic, dynamically |
| `Hi` | neutral | 0 | srf, tremend, practition, cryptoc, mathemat, princ |
| `Greetings` _(stiff/formal)_ | neutral | 0 | flavoring, below, software, monthly, released, asset |

## opinion_noun — _a stated personal view_

| word | pulls toward | hits | makes likelier (next token) |
|---|---|---|---|
| `position` _(formal/legal)_ | legal / formal | 2 | directive, directives, relevant, specified, normative, delim |
| `opinion` | academic | 2 | divisive, strongest, polarized, passionately, mainly, unanimous |
| `hot take` _(Reddit/Twitter)_ | neutral | 1 | dating, emails, celeb, hotter, heats, sexy |
| `take` _(casual/Reddit)_ | neutral | 0 | suppose, unintention, guiicon, teasp, accounts, consider |
| `two cents` _(casual idiom)_ | neutral | 0 | macy, sold, rite, coupon, coupons, amtrak |
| `assessment` _(academic/corporate)_ | neutral | 0 | oecd, favourable, mitigation, brexit, resettlement, sustained |

## good_adj — _positive evaluation_

| word | pulls toward | hits | makes likelier (next token) |
|---|---|---|---|
| `superb` _(formal/marketing)_ | marketing hype | 3 | highly, featuring, wonderful, excellence, pair, emin |
| `good` | neutral | 0 | but, nevertheless, bye, recomm, tod, else |
| `great` | neutral | 0 | lyft, feedback, thank, integration, downloads, sharing |
| `excellent` _(formal)_ | neutral | 0 | highly, selection, service, customer, delivery, ingredients |
| `awesome` _(casual)_ | neutral | 0 | volunte, srf, entreprene, tradem, carbohyd, tremend |
| `fire` _(Gen-Z slang)_ | neutral | 0 | extingu, arson, blaze, flames, combust, extinguished |
| `decent` | neutral | 0 | but, nonetheless, nevertheless, however, mediocre, still |

## investigate_verb — _to examine something_

| word | pulls toward | hits | makes likelier (next token) |
|---|---|---|---|
| `audit` _(corporate/legal)_ | corporate | 3 | cert, certify, certification, inspect, certific, certificate |
| `investigate` | neutral | 1 | enqu, unlawfully, endeavour, contact, inform, exting |
| `look into` | neutral | 0 | syrians, ukrainians, latinos, krish, africans, sov |
| `dig into` _(casual)_ | neutral | 0 | krugman, digs, sack, gross, hungry, dre |
| `check out` _(casual)_ | neutral | 0 | pione, earthqu, coupon, randomredditor, externaltoeva, thenitrome |
| `probe` _(journalistic/formal)_ | neutral | 0 | probing, mosqu, interrog, suspic, forcefully, penet |

## people_noun — _a group of persons_

| word | pulls toward | hits | makes likelier (next token) |
|---|---|---|---|
| `guys` _(casual)_ | Reddit / casual | 10 | dudes, dude, fuckin, yeah, gotta, shit |
| `stakeholders` _(corporate)_ | corporate | 6 | ngos, policymakers, implementation, feder, governments, organisations |
| `individuals` _(formal/academic)_ | legal / formal | 4 | plaint, plaintiff, counsel, attorney, defendants, investigators |
| `everyone` | Reddit / casual | 2 | gobl, tremend, spoilers, sweets, haha, conflic |
| `people` | neutral | 0 | peacefully, pray, tears, abortion, evacuate, forgive |
| `folks` _(casual/Reddit)_ | neutral | 0 | check, tune, turns, here, enjoy, stay |

## discuss_verb — _to talk about_

| word | pulls toward | hits | makes likelier (next token) |
|---|---|---|---|
| `discuss` | neutral | 0 | procedure, appendix, summarize, summarizes, suppose, considerations |
| `talk about` | neutral | 0 | obamacare, republicans, reagan, obama, nafta, president |
| `chat about` _(casual)_ | neutral | 0 | tremend, carbohyd, volunte, practition, teasp, councill |
| `touch base on` _(corporate)_ | neutral | 0 | consumers, yet, forbes, rather, manufacturing, advertising |
| `deliberate on` _(formal/legal)_ | neutral | 0 | otherwise, reduce, removal, period, remove, instead |

## intensifier — _degree amplifier_

| word | pulls toward | hits | makes likelier (next token) |
|---|---|---|---|
| `hella` _(Gen-Z/West-coast slang)_ | Reddit / casual | 10 | dunno, goddamn, godd, fuckin, fuck, shit |
| `extremely` _(formal)_ | academic | 6 | significant, numerous, strengthened, unprecedented, considerable, stringent |
| `incredibly` _(marketing)_ | marketing hype | 6 | transformative, empowering, profound, groundbreaking, unparalleled, countless |
| `super` _(casual)_ | Reddit / casual | 3 | shirt, awesome, lol, haha, plus, tags |
| `very` | neutral | 0 | bilateral, reciprocal, tariff, bilingual, residential, unilateral |
| `really` | neutral | 0 | learners, uptake, fragmentation, maybe, kind, parcels |

## money_noun — _financial resources_

| word | pulls toward | hits | makes likelier (next token) |
|---|---|---|---|
| `capital` _(corporate/finance)_ | corporate | 4 | cities, infrastructure, redevelopment, investment, metropolitan, investments |
| `cash` _(casual)_ | corporate | 2 | gambling, payments, poker, liquidity, gamb, dividend |
| `money` | neutral | 1 | transparency, scholarships, daca, scholarship, salary, medicare |
| `bucks` _(casual)_ | neutral | 1 | cowboy, buffalo, females, panther, whine, cow |
| `funds` _(formal)_ | neutral | 0 | funding, cosponsors, nct, donations, fundraising, funded |
| `dough` _(slang)_ | neutral | 0 | pastry, bake, baking, oven, bisc, gluten |
