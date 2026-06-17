# The LLM Word→Register Dictionary

_Derived empirically from **gpt2** via next-token register mass. Each word is grouped under the register its distinctive next-token fingerprint matches. `hits` = how many of the word's boosted tokens are register markers; `mass_z` = next-token probability mass on that register (std-devs above the word's synonyms)._

**How to use it.** Pick a meaning, then choose the synonym whose register you want. *"Give me your hot take"* and *"give me your assessment"* are the same request — but the first word tilts the model's next-token distribution toward casual/forum language and the second toward formal/analytic language, and that tilt compounds across every following token into a whole different answer.

_`neutral` = the word's strongest associations were literal or idiosyncratic rather than register-marking — notably slang whose literal sense dominates in a base model (`dough`→baking, `fire`→arson, `bucks`→buffalo)._

## Pulls toward: Reddit / casual

| word | meaning | hits | mass_z | makes likelier |
|---|---|---|---|---|
| **hella** | degree amplifier | 10 | +2.07 | dunno, goddamn, godd, fuckin, fuck, shit |
| **guys** | a group of persons | 10 | +0.58 | dudes, dude, fuckin, yeah, gotta, shit |
| **Hey** | an opening salutation | 6 | +1.03 | trayvon, philly, yeah, whitney, blah, lebron |
| **super** | degree amplifier | 3 | +0.20 | shirt, awesome, lol, haha, plus, tags |
| **Yo** | an opening salutation | 3 | +0.11 | kobe, kendrick, rappers, lebron, kanye, tup |
| **everyone** | a group of persons | 2 | +0.22 | gobl, tremend, spoilers, sweets, haha, conflic |

## Pulls toward: corporate

| word | meaning | hits | mass_z | makes likelier |
|---|---|---|---|---|
| **stakeholders** | a group of persons | 6 | +0.89 | ngos, policymakers, implementation, feder, governments, organisations |
| **capital** | financial resources | 4 | +1.91 | cities, infrastructure, redevelopment, investment, metropolitan, investments |
| **audit** | to examine something | 3 | -0.15 | cert, certify, certification, inspect, certific, certificate |
| **cash** | financial resources | 2 | -0.28 | gambling, payments, poker, liquidity, gamb, dividend |

## Pulls toward: marketing hype

| word | meaning | hits | mass_z | makes likelier |
|---|---|---|---|---|
| **incredibly** | degree amplifier | 6 | +0.13 | transformative, empowering, profound, groundbreaking, unparalleled, countless |
| **superb** | positive evaluation | 3 | +1.58 | highly, featuring, wonderful, excellence, pair, emin |

## Pulls toward: legal / formal

| word | meaning | hits | mass_z | makes likelier |
|---|---|---|---|---|
| **individuals** | a group of persons | 4 | -0.41 | plaint, plaintiff, counsel, attorney, defendants, investigators |
| **position** | a stated personal view | 2 | +1.15 | directive, directives, relevant, specified, normative, delim |
| **Dear Sir or Madam** | an opening salutation | 2 | +0.74 | apologise, labour, ministers, fulfil, enqu, parliamentary |

## Pulls toward: academic

| word | meaning | hits | mass_z | makes likelier |
|---|---|---|---|---|
| **extremely** | degree amplifier | 6 | +1.74 | significant, numerous, strengthened, unprecedented, considerable, stringent |
| **opinion** | a stated personal view | 2 | -0.50 | divisive, strongest, polarized, passionately, mainly, unanimous |

## Pulls toward: neutral

| word | meaning | hits | mass_z | makes likelier |
|---|---|---|---|---|
| **hot take** | a stated personal view | 1 | +0.00 | dating, emails, celeb, hotter, heats, sexy |
| **investigate** | to examine something | 1 | +0.00 | enqu, unlawfully, endeavour, contact, inform, exting |
| **money** | financial resources | 1 | +0.00 | transparency, scholarships, daca, scholarship, salary, medicare |
| **bucks** | financial resources | 1 | +0.00 | cowboy, buffalo, females, panther, whine, cow |
| **Hello** | an opening salutation | 0 | +0.00 | satell, srf, synchronization, statically, conflic, dynamically |
| **Hi** | an opening salutation | 0 | +0.00 | srf, tremend, practition, cryptoc, mathemat, princ |
| **Greetings** | an opening salutation | 0 | +0.00 | flavoring, below, software, monthly, released, asset |
| **take** | a stated personal view | 0 | +0.00 | suppose, unintention, guiicon, teasp, accounts, consider |
| **two cents** | a stated personal view | 0 | +0.00 | macy, sold, rite, coupon, coupons, amtrak |
| **assessment** | a stated personal view | 0 | +0.00 | oecd, favourable, mitigation, brexit, resettlement, sustained |
| **good** | positive evaluation | 0 | +0.00 | but, nevertheless, bye, recomm, tod, else |
| **great** | positive evaluation | 0 | +0.00 | lyft, feedback, thank, integration, downloads, sharing |
| **excellent** | positive evaluation | 0 | +0.00 | highly, selection, service, customer, delivery, ingredients |
| **awesome** | positive evaluation | 0 | +0.00 | volunte, srf, entreprene, tradem, carbohyd, tremend |
| **fire** | positive evaluation | 0 | +0.00 | extingu, arson, blaze, flames, combust, extinguished |
| **decent** | positive evaluation | 0 | +0.00 | but, nonetheless, nevertheless, however, mediocre, still |
| **look into** | to examine something | 0 | +0.00 | syrians, ukrainians, latinos, krish, africans, sov |
| **dig into** | to examine something | 0 | +0.00 | krugman, digs, sack, gross, hungry, dre |
| **check out** | to examine something | 0 | +0.00 | pione, earthqu, coupon, randomredditor, externaltoeva, thenitrome |
| **probe** | to examine something | 0 | +0.00 | probing, mosqu, interrog, suspic, forcefully, penet |
| **people** | a group of persons | 0 | +0.00 | peacefully, pray, tears, abortion, evacuate, forgive |
| **folks** | a group of persons | 0 | +0.00 | check, tune, turns, here, enjoy, stay |
| **discuss** | to talk about | 0 | +0.00 | procedure, appendix, summarize, summarizes, suppose, considerations |
| **talk about** | to talk about | 0 | +0.00 | obamacare, republicans, reagan, obama, nafta, president |
| **chat about** | to talk about | 0 | +0.00 | tremend, carbohyd, volunte, practition, teasp, councill |
| **touch base on** | to talk about | 0 | +0.00 | consumers, yet, forbes, rather, manufacturing, advertising |
| **deliberate on** | to talk about | 0 | +0.00 | otherwise, reduce, removal, period, remove, instead |
| **very** | degree amplifier | 0 | +0.00 | bilateral, reciprocal, tariff, bilingual, residential, unilateral |
| **really** | degree amplifier | 0 | +0.00 | learners, uptake, fragmentation, maybe, kind, parcels |
| **funds** | financial resources | 0 | +0.00 | funding, cosponsors, nct, donations, fundraising, funded |
| **dough** | financial resources | 0 | +0.00 | pastry, bake, baking, oven, bisc, gluten |
