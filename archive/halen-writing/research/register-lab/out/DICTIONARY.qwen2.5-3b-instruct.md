# The LLM Word→Register Dictionary

_Derived empirically from **Qwen/Qwen2.5-3B-Instruct** via next-token register fingerprint. Each word is grouped under the register its distinctive next-token fingerprint matches. `hits` = how many of the word's boosted tokens are register markers; `mass_z` = next-token probability mass on that register (std-devs above the word's synonyms)._

**How to use it.** Pick a meaning, then choose the synonym whose register you want. *"Give me your hot take"* and *"give me your assessment"* are the same request — but the first word tilts the model's next-token distribution toward casual/forum language and the second toward formal/analytic language, and that tilt compounds across every following token into a whole different answer.

_`neutral` = the word's strongest associations were literal or idiosyncratic rather than register-marking — notably slang whose literal sense dominates in a base model (`dough`→baking, `fire`→arson, `bucks`→buffalo)._

## Pulls toward: Reddit / casual

| word | meaning | hits | mass_z | makes likelier |
|---|---|---|---|---|
| **Yo** | an opening salutation | 9 | +0.83 | gotta, shit, dude, dudes, yeah, vibes |
| **Hey** | an opening salutation | 8 | +0.21 | dudes, gotta, anybody, nope, yeah, dude |
| **hella** | degree amplifier | 7 | +2.19 | dang, kinda, fuck, banda, fucking, dope |
| **hot take** | a stated personal view | 4 | -0.56 | fucking, shit, shitty, fucked, damn, fuck |
| **guys** | a group of persons | 2 | +1.29 | squad, coach, played, player, workout, fucked |
| **everyone** | a group of persons | 2 | -1.69 | haha, lol, its, thats, ima, theres |

## Pulls toward: academic

| word | meaning | hits | mass_z | makes likelier |
|---|---|---|---|---|
| **extremely** | degree amplifier | 5 | -0.75 | macedonia, extensive, substantial, numerous, evans, significant |
| **Greetings** | an opening salutation | 2 | +1.02 | eos, stefan, inherently, asf, jedoch, whim |

## Pulls toward: corporate

| word | meaning | hits | mass_z | makes likelier |
|---|---|---|---|---|
| **stakeholders** | a group of persons | 4 | +1.43 | regulatory, contractors, regulators, audit, governance, telecom |
| **capital** | financial resources | 3 | +1.53 | equity, asset, investors, debt, investment, ipo |

## Pulls toward: marketing hype

| word | meaning | hits | mass_z | makes likelier |
|---|---|---|---|---|
| **superb** | positive evaluation | 2 | +1.49 | stunning, maver, jacqu, juda, sax, exceptional |

## Pulls toward: neutral

| word | meaning | hits | mass_z | makes likelier |
|---|---|---|---|---|
| **Hello** | an opening salutation | 1 | +0.00 | increasing, eos, pricing, gentle, ticket, export |
| **Dear Sir or Madam** | an opening salutation | 1 | +0.00 | yours, your, usted, yourself, although, regards |
| **excellent** | positive evaluation | 1 | +0.00 | delighted, congratulate, congrat, unparalleled, outstanding, enthusiastically |
| **investigate** | to examine something | 1 | +0.00 | investigation, investigations, investigating, investigación, investigative, investigators |
| **individuals** | a group of persons | 1 | +0.00 | physicians, legisl, examinations, commencement, establishments, representatives |
| **touch base on** | to talk about | 1 | +0.00 | recap, collateral, audit, vendor, triple, billed |
| **incredibly** | degree amplifier | 1 | +0.00 | democrat, garg, transparency, map, staggering, thoroughly |
| **cash** | financial resources | 1 | +0.00 | cfo, barclays, liquidity, investors, salesforce, asset |
| **Hi** | an opening salutation | 0 | +0.00 | eos, sql, stefan, loader, rst, maur |
| **opinion** | a stated personal view | 0 | +0.00 | arou, refers, whether |
| **take** | a stated personal view | 0 | +0.00 | specialised, birthday, exemple, purified, inspiration, simplified |
| **two cents** | a stated personal view | 0 | +0.00 | ensure, encourage, avail, appreciate, simplify, appreciated |
| **assessment** | a stated personal view | 0 | +0.00 | sudan, rwanda, aleppo, riyadh, jakarta, kabul |
| **position** | a stated personal view | 0 | +0.00 | advocate, supervisor, negotiations, district, modifications, amendment |
| **good** | positive evaluation | 0 | +0.00 |  |
| **great** | positive evaluation | 0 | +0.00 | lots, tomorrow, celebrate, room, celebrating, jenny |
| **awesome** | positive evaluation | 0 | +0.00 | pics |
| **fire** | positive evaluation | 0 | +0.00 | flames, arson, burns, flame, poison, النار |
| **decent** | positive evaluation | 0 | +0.00 | average, neither, moderately, fair, midpoint, somewhat |
| **look into** | to examine something | 0 | +0.00 | noticed, dated, staff, xpar, recently, sma |
| **dig into** | to examine something | 0 | +0.00 | first, essentially, santos, nation, nuggets, clearly |
| **check out** | to examine something | 0 | +0.00 | http, ciné, tys, swiper, gif, mec |
| **probe** | to examine something | 0 | +0.00 | probing, craft, exploit, exploiting, provoke, manip |
| **audit** | to examine something | 0 | +0.00 | defects, audrey, ris, csv, flaws, func |
| **people** | a group of persons | 0 | +0.00 | young, study, activism, tłum, shouting, shout |
| **folks** | a group of persons | 0 | +0.00 | normalized, datasets, gardening, soak, sez, bicy |
| **discuss** | to talk about | 0 | +0.00 | belongs, judge, belong, improperly, belonging, hollow |
| **talk about** | to talk about | 0 | +0.00 |  |
| **chat about** | to talk about | 0 | +0.00 | alf, angeles, melania, linkedin, afs, faqs |
| **deliberate on** | to talk about | 0 | +0.00 | devoid, painstaking, ponder, contemplate, meticulously, populace |
| **very** | degree amplifier | 0 | +0.00 | thailand, duke, beijing, huawei, qin, associated |
| **really** | degree amplifier | 0 | +0.00 | geile |
| **super** | degree amplifier | 0 | +0.00 | seks, garg, siêu, mysql, spa, fitting |
| **money** | financial resources | 0 | +0.00 | lithuania, britain, tuition, obamacare, taxes, poverty |
| **funds** | financial resources | 0 | +0.00 | telecommunications, railway, scholarships, xiao, tele, provincial |
| **bucks** | financial resources | 0 | +0.00 | deer, hunters, hunter, mating, hunts, nymph |
| **dough** | financial resources | 0 | +0.00 | gluten, bake, baking, baked, bread, flour |
