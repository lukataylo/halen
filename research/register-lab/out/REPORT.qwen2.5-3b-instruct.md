# Register Lab — the mechanism: word choice reshapes P(next token)

_Model: **Qwen/Qwen2.5-3B-Instruct** · method: next-token register fingerprint · 52.3s_

Each synonym is dropped into identical carrier sentences; the only variable is the one word. We then read the model's **next-token distribution** and rank the tokens this word makes likelier than its synonyms do — its *register fingerprint*. The label is assigned by how many of those distinctive tokens fall into a register's vocabulary (`hits`); `mass_z` is a second, distributional check (how much next-token probability mass the word puts on that register's markers, in std-devs above its synonyms).

## Clearest single-word register fingerprints

| word | cluster | pulls toward | fingerprint hits | mass_z |
|---|---|---|---|---|
| `Yo` | greeting | **Reddit / casual** | 9 | +0.83 |
| `Hey` | greeting | **Reddit / casual** | 8 | +0.21 |
| `hella` | intensifier | **Reddit / casual** | 7 | +2.19 |
| `extremely` | intensifier | **academic** | 5 | -0.75 |
| `stakeholders` | people_noun | **corporate** | 4 | +1.43 |
| `hot take` | opinion_noun | **Reddit / casual** | 4 | -0.56 |
| `capital` | money_noun | **corporate** | 3 | +1.53 |
| `superb` | good_adj | **marketing hype** | 2 | +1.49 |
| `guys` | people_noun | **Reddit / casual** | 2 | +1.29 |
| `Greetings` | greeting | **academic** | 2 | +1.02 |
| `everyone` | people_noun | **Reddit / casual** | 2 | -1.69 |

## greeting — _an opening salutation_

| word | pulls toward | hits | makes likelier (next token) |
|---|---|---|---|
| `Yo` _(Gen-Z / street)_ | Reddit / casual | 9 | gotta, shit, dude, dudes, yeah, vibes |
| `Hey` _(casual/Reddit)_ | Reddit / casual | 8 | dudes, gotta, anybody, nope, yeah, dude |
| `Greetings` _(stiff/formal)_ | academic | 2 | eos, stefan, inherently, asf, jedoch, whim |
| `Hello` | neutral | 1 | increasing, eos, pricing, gentle, ticket, export |
| `Dear Sir or Madam` _(legal/formal letter)_ | neutral | 1 | yours, your, usted, yourself, although, regards |
| `Hi` | neutral | 0 | eos, sql, stefan, loader, rst, maur |

## opinion_noun — _a stated personal view_

| word | pulls toward | hits | makes likelier (next token) |
|---|---|---|---|
| `hot take` _(Reddit/Twitter)_ | Reddit / casual | 4 | fucking, shit, shitty, fucked, damn, fuck |
| `opinion` | neutral | 0 | arou, refers, whether |
| `take` _(casual/Reddit)_ | neutral | 0 | specialised, birthday, exemple, purified, inspiration, simplified |
| `two cents` _(casual idiom)_ | neutral | 0 | ensure, encourage, avail, appreciate, simplify, appreciated |
| `assessment` _(academic/corporate)_ | neutral | 0 | sudan, rwanda, aleppo, riyadh, jakarta, kabul |
| `position` _(formal/legal)_ | neutral | 0 | advocate, supervisor, negotiations, district, modifications, amendment |

## good_adj — _positive evaluation_

| word | pulls toward | hits | makes likelier (next token) |
|---|---|---|---|
| `superb` _(formal/marketing)_ | marketing hype | 2 | stunning, maver, jacqu, juda, sax, exceptional |
| `excellent` _(formal)_ | neutral | 1 | delighted, congratulate, congrat, unparalleled, outstanding, enthusiastically |
| `good` | neutral | 0 |  |
| `great` | neutral | 0 | lots, tomorrow, celebrate, room, celebrating, jenny |
| `awesome` _(casual)_ | neutral | 0 | pics |
| `fire` _(Gen-Z slang)_ | neutral | 0 | flames, arson, burns, flame, poison, النار |
| `decent` | neutral | 0 | average, neither, moderately, fair, midpoint, somewhat |

## investigate_verb — _to examine something_

| word | pulls toward | hits | makes likelier (next token) |
|---|---|---|---|
| `investigate` | neutral | 1 | investigation, investigations, investigating, investigación, investigative, investigators |
| `look into` | neutral | 0 | noticed, dated, staff, xpar, recently, sma |
| `dig into` _(casual)_ | neutral | 0 | first, essentially, santos, nation, nuggets, clearly |
| `check out` _(casual)_ | neutral | 0 | http, ciné, tys, swiper, gif, mec |
| `probe` _(journalistic/formal)_ | neutral | 0 | probing, craft, exploit, exploiting, provoke, manip |
| `audit` _(corporate/legal)_ | neutral | 0 | defects, audrey, ris, csv, flaws, func |

## people_noun — _a group of persons_

| word | pulls toward | hits | makes likelier (next token) |
|---|---|---|---|
| `stakeholders` _(corporate)_ | corporate | 4 | regulatory, contractors, regulators, audit, governance, telecom |
| `guys` _(casual)_ | Reddit / casual | 2 | squad, coach, played, player, workout, fucked |
| `everyone` | Reddit / casual | 2 | haha, lol, its, thats, ima, theres |
| `individuals` _(formal/academic)_ | neutral | 1 | physicians, legisl, examinations, commencement, establishments, representatives |
| `people` | neutral | 0 | young, study, activism, tłum, shouting, shout |
| `folks` _(casual/Reddit)_ | neutral | 0 | normalized, datasets, gardening, soak, sez, bicy |

## discuss_verb — _to talk about_

| word | pulls toward | hits | makes likelier (next token) |
|---|---|---|---|
| `touch base on` _(corporate)_ | neutral | 1 | recap, collateral, audit, vendor, triple, billed |
| `discuss` | neutral | 0 | belongs, judge, belong, improperly, belonging, hollow |
| `talk about` | neutral | 0 |  |
| `chat about` _(casual)_ | neutral | 0 | alf, angeles, melania, linkedin, afs, faqs |
| `deliberate on` _(formal/legal)_ | neutral | 0 | devoid, painstaking, ponder, contemplate, meticulously, populace |

## intensifier — _degree amplifier_

| word | pulls toward | hits | makes likelier (next token) |
|---|---|---|---|
| `hella` _(Gen-Z/West-coast slang)_ | Reddit / casual | 7 | dang, kinda, fuck, banda, fucking, dope |
| `extremely` _(formal)_ | academic | 5 | macedonia, extensive, substantial, numerous, evans, significant |
| `incredibly` _(marketing)_ | neutral | 1 | democrat, garg, transparency, map, staggering, thoroughly |
| `very` | neutral | 0 | thailand, duke, beijing, huawei, qin, associated |
| `really` | neutral | 0 | geile |
| `super` _(casual)_ | neutral | 0 | seks, garg, siêu, mysql, spa, fitting |

## money_noun — _financial resources_

| word | pulls toward | hits | makes likelier (next token) |
|---|---|---|---|
| `capital` _(corporate/finance)_ | corporate | 3 | equity, asset, investors, debt, investment, ipo |
| `cash` _(casual)_ | neutral | 1 | cfo, barclays, liquidity, investors, salesforce, asset |
| `money` | neutral | 0 | lithuania, britain, tuition, obamacare, taxes, poverty |
| `funds` _(formal)_ | neutral | 0 | telecommunications, railway, scholarships, xiao, tele, provincial |
| `bucks` _(casual)_ | neutral | 0 | deer, hunters, hunter, mating, hunts, nymph |
| `dough` _(slang)_ | neutral | 0 | gluten, bake, baking, baked, bread, flour |
