# Proposal 001 — Making loot distribution fairer over time

> **Status: DECIDED — Option 3, Suicide Kings, chosen for v1.**
>
> Options 1 and 2 are deferred to the [roadmap](../ROADMAP.md) with their reasoning intact.
> Implementation: [spec 010](../specs/010-priority-list.md).
>
> This document is kept as the comparison that produced the decision. If someone wants to
> re-open it, this is what they should argue with.

---

## 1. The problem

The rules in [DESIGN.md](../DESIGN.md) have no memory. Every item is judged on your hierarchy
and a d100, and nothing else. Over one item that is exactly right. Over a raid tier it produces
an outcome nobody actually wants:

> Four things you needed dropped tonight. You won none of them. Someone else won three.
> On the fifth, the rules treat you both identically.

That is not a bug in the roll — it is what an independent lottery does. Rolls cluster. The fix
is to give the system a memory.

Three options were considered. All three keep the hierarchy and the tier gate exactly as they
are: a T1 entry still beats a T2 entry, always. They differ in what happens **inside** a tier,
where several characters are genuinely competing.

## 2. Option 1 — Tier adjustment *(not chosen)*

Keep a **ledger** of what each player's roster has recently received — per owning player, over
the last 12 loot-bearing bosses, delivered items only. For each item, the entrant who has
received least sets a baseline; everyone else drops one tier per item they are ahead, capped at
two.

A demotion could push below Rest, shown as `Rest −1`.

**Character:** blunt and decisive. Being one item ahead does not make you slightly less likely to
win — it takes you out of contention, because a lower tier is never consulted while a higher one
can supply a winner.

**Why it lost:** it is the only one of the three that can override the hierarchy, and the group
preferred a system where a high ranking still means what it says. It also required accepting that
Rest is no longer strictly equal chance.

## 3. Option 2 — Roll adjustment *(not chosen)*

The same ledger, but weighing items by **GearScore** rather than counting them, with older wins
fading — half-life six bosses. Players who are ahead roll at a penalty: being one average item
ahead costs 15 points out of 100, capped at 30. Tiers untouched.

```
Bonk   (Dave)   T1   88 − 12 = 76
Chop   (Anna)   T1   41 −  0 = 41
```

**Character:** gentle and continuous. No cliff edges, and it can never overturn the hierarchy.

**Why it lost:** too polite to fix the problem it was built for. It only reorders people already
competing directly, does nothing where one person's top tier is uncontested, and — the deciding
objection — nobody can answer *"where will I stand tomorrow?"* without a calculator. Its
adjustment is a decayed weighted number that moves every raid.

## 4. Option 3 — Suicide Kings *(chosen)*

A single ordered list of **every character** in the raid, shuffled once at the start.

When an item drops, tier gating applies exactly as today. Inside a tier, **the character highest
on the list wins.** No roll. That character then drops to the **bottom** of the list, and
everyone below it moves up one.

That is the whole system.

- **Nothing is random.** Once the list is seeded, every outcome is a fact you can look up in
  advance, and disputes end by pointing at a number.
- **Your position only improves while you wait.** Losing costs you nothing; not entering costs
  you nothing. Priority is earned purely by not having won recently.
- **Characters, not players.** Your mage winning sinks your mage. Your rogue keeps its place — so
  your bots getting kitted out never costs your main its priority.
- **Characters not in the raid don't move.** A bot left at home doesn't drift up the list while
  everyone else raids.

### What it costs

**The guarantee only holds inside a tier.** Classic Suicide Kings promises: *wait long enough,
reach the top, and the next thing you want is yours.* Because we keep the tier gate, that promise
holds only among characters in the same bucket. If Anna's main is the raid's only warrior, she
takes every plate item at T1 forever, however far down the list she falls.

What limits it: **an uncontested win still suicides you.** Anna keeps her uncontested plate, but
she drops down the list and stops winning the *contested* things — tokens, weapons, trinkets. The
list works where people are actually competing and is inert where nobody is.

**Ticking a box is still free at the player level.** Suicide Kings is often described as making
entry a real decision, because entering costs you your position. With a per-character list, that
pressure exists per character: your bot spends its own place, not yours. Don't expect the
strategic layer that guild write-ups describe.

### Two rules that classic Suicide Kings doesn't need

Classic SK resolves one item at a time, by hand. We resolve a whole boss at once, which creates a
problem: your mage has one position but six items to want.

1. **One win per character per batch.** A character that wins is withdrawn from the rest of that
   boss's items. Without this, being top of the list and ticking everything wins you everything,
   for the price of one suicide.
2. **The priority pick.** Each character stars **one** of its ticked items. If it would win more
   than one, the star decides which. Starring costs nothing — it is consulted only when you would
   genuinely have won several — and without it your mage wins the junk ring in loot slot 1 and
   loses the weapon in slot 4 to arbitrary ordering.

## 5. Side by side

| | **1. Tier adjustment** | **2. Roll adjustment** | **3. Suicide Kings** |
|---|---|---|---|
| Deterministic? | No | No | **Yes** |
| Can you predict your standing? | Roughly | Not really | **Exactly** |
| What decides inside a tier | Tier drop, then a roll | A penalised roll | List position |
| Can it overturn the hierarchy? | Yes | No | No |
| Unit | Owning player | Owning player | **Character** |
| Item value matters? | No | Yes, GearScore | No |
| Effect on a solo top-tier entry | Can hand it to a lower tier | None | None, but still suicides |
| State it keeps | Derived tally | Derived tally | **An ordered list that must not drift** |
| Main risk | Overcorrects | Undercorrects | Tier gating blunts it |

## 6. Worked example

Mid-raid. Tier count 3. A plate chest drops. Five characters are entered:

| Character | Owner | Tier | List position |
|---|---|---|---|
| Chop | Anna | T1 | 14 |
| Bonk | Dave | T1 | 2 |
| Smash | Steve | T3 | 1 |
| Rusty | Priya | Rest | 5 |
| Grim | Tom | Rest | 3 |

**Under the old rules.** Anna and Dave roll it out at T1. Anyone can win.

**Under Suicide Kings.** T1 is occupied, so nothing below it is consulted — Steve's position 1
is irrelevant, because his warrior is a T3 entry and a T1 entry exists. Between Chop (14) and
Bonk (2), **Bonk wins**, with no roll. Bonk goes to the bottom of the list; Chop moves up to 13,
and so does everyone else below Bonk who is in the raid.

Next time a plate chest drops and both want it, Chop wins.

## 7. What it does not do

- **No gear awareness.** An undergeared bot gets no priority for being undergeared. That needs
  gear data that only exists when someone runs a manual scan with everyone in range. On the
  [roadmap](../ROADMAP.md).
- **No sense of what you need.** Winning a marginal upgrade costs your character exactly as much
  as winning its best-in-slot.
- **No item weighting.** A ring and a weapon both cost one suicide.
- **Nothing for passing.** Passing earns no credit; only winning costs you.

## 8. Settings

`ROLL` — the original rules — stays available and is the **default**. Seeding the priority list
is the deliberate act that makes Suicide Kings selectable, so there is no half-configured state
to get stuck in. The raid leader can reseed, reorder and manually correct the list; every such
change is announced in raid chat and recorded.

The initial shuffle uses a **published seed**, so anyone can reproduce it and check.
