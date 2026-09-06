# Proposal 001 — Making loot distribution fairer over time

**Status:** open, awaiting review.
**Decision needed:** pick one of three settings — **Off**, **Tier adjustment**, or **Roll
adjustment**.

---

## 1. The problem

The rules in [DESIGN.md](../DESIGN.md) have no memory. Every item is judged on your hierarchy
and a d100, and nothing else. Over one item that is exactly right. Over a raid tier it produces
an outcome nobody actually wants:

> Four things you needed dropped tonight. You won none of them. Someone else won three.
> On the fifth, the rules treat you both identically.

That is not a bug in the roll — it is what an independent lottery does. Rolls cluster. The fix
is to give the system a memory: **the more you have recently received, the less the rules
favour you.**

Both options below do exactly that, and they differ only in *how* they intervene. Both are
optional, both are off unless the raid leader turns them on, and both are visible to everyone
before you commit an entry.

## 2. What both options share: the ledger

Whichever option we pick, the addon keeps a **ledger** — a running record of what each player's
roster has recently received.

**The ledger counts players, not characters.** Your whole roster shares one entry. If your mage
main wins a weapon, your rogue bot carries that too.

> **Why:** the entire point of ranking your mage 1st is that it eats first. A per-character
> ledger would demote it *for doing exactly that*, quietly flattening your own hierarchy over a
> night. Player-level accounting leaves your internal ordering completely untouched and only
> arbitrates *between* rosters — which is the thing that actually feels unfair.
>
> This assumes rosters are roughly the same size. Ours are. If that changes, the ledger becomes
> unfair in the opposite direction and needs revisiting.

**What goes in it:**

- Only items **actually delivered**. An award that failed, or that you never received, does not
  count against you — and if a delivery later fails, the ledger gives it back.
- Only items at or above the raid's quality threshold (epic by default).
- Items nobody claimed, and items you passed on, do nothing.

**How far back it looks:** the last **12 loot-bearing bosses**, and nothing older than **14
days**. Bosses that dropped nothing relevant don't age the window.

> **Note:** this is deliberately *not* "tonight only". The window spans nights — if last night
> ended six bosses ago, tonight's first roll already knows about it. Fairness across a week of
> raiding is a stronger property than fairness within one evening, and a nightly reset would
> mean whoever cleaned up on Tuesday starts Wednesday level with everyone.

**It is completely public.** The master looter's ledger is broadcast to the raid when a roll
opens, and the roll window shows everyone's standing. There is no hidden number moving your
odds. If the master looter's ledger looks wrong — they joined late, they reinstalled — everyone
can see that it looks wrong and say so.

**It resolves item by item within a boss.** If a boss drops four things and you win the first,
you carry that weight into the other three. A boss dropping four epics is exactly where "one
person took everything" happens, and freezing the ledger at the start of the roll would switch
the feature off at the worst possible moment.

---

## 3. Option 1 — Tier adjustment

**Players who are ahead drop tiers for that item.**

Your tier comes from your hierarchy as it does today. Then, for each item, the addon compares
you against **the other people entering that specific item**. Whoever has received least among
them sets the baseline and is unaffected. Everyone else drops one tier per item they are ahead,
to a maximum of two tiers.

| Items ahead of the field | Adjustment |
|---|---|
| 0 | none |
| 1 | −1 tier |
| 2 | −2 tiers |
| 3 or more | −2 tiers (capped) |

A demotion can push you **below Rest**, shown as `Rest −1` and `Rest −2`. Rest is where most bot
loot is actually decided, so an adjustment that couldn't reach into it would barely do anything.

> **This means Rest is no longer strictly "equal chance"** — it is equal chance *before* the
> adjustment. That is a real change to a promise the design currently makes, and it is the main
> thing to weigh up about this option.

Your own ordering is preserved: every character you enter for an item is adjusted by the same
amount, so your mage still sits above your rogue.

### What this feels like

Blunt and decisive. Being one item ahead does not make you slightly less likely to win — it can
take you out of contention entirely, because a lower tier is never consulted while a higher one
can supply a winner. When it fires, it fires hard.

---

## 4. Option 2 — Roll adjustment

**Players who are ahead roll with a penalty. Tiers are untouched.**

Your tier is exactly what your hierarchy says, always. Instead, within each tier, players who
have received more recently roll at a disadvantage.

**Items are weighed, not counted.** A 264 weapon is worth far more than a 232 ring, and this
option measures that using **GearScore** — the same scale PlayerbotManager already shows you.
Winning a big upgrade costs you more than winning a trinket.

**Older wins fade.** A win loses half its weight every **6 loot-bearing bosses** — roughly half a
raid night. Something from earlier this evening still bites hard; something from a night ago is
worth about half; from two nights ago, about a quarter. It fades by *bosses elapsed*, not by
time, so a fortnight's break doesn't forgive anything a week of raiding wouldn't have.

**The penalty:** being one average item ahead of the field costs **15 roll points**, out of 100.
The penalty is capped at **30** — roughly two items — so it never becomes mathematically
impossible to win, it just becomes hard.

The roll window shows the arithmetic, never just the result:

```
Bonk   (Dave)   T1   88 − 12 = 76
Chop   (Anna)   T1   41 −  0 = 41     <- Anna has received nothing recently
```

### What this feels like

Gentle and continuous. There are no cliff edges: one more item makes you a bit worse off, not
suddenly ineligible. But it also **can never overturn your hierarchy** — a T1 entry still beats
every T2 entry no matter how much loot that player has taken, because tiers are still walked
strictly. It only reorders people who were already competing directly.

It also does **nothing** on an item where only one person's top tier is entered, which is
common.

---

## 5. Side by side

| | **Tier adjustment** | **Roll adjustment** |
|---|---|---|
| What moves | Your tier, for one item | Your roll, within your tier |
| Strength | Strong — can remove you from contention | Gentle — makes you a slight underdog |
| Counts | Items, equally | Item value, via GearScore |
| Older wins | Count fully inside the window, then vanish | Fade smoothly, half-life 6 bosses |
| Can it overturn the hierarchy? | **Yes** — that is the mechanism | **No**, ever |
| Effect inside Rest | Strong (can push below Rest) | Strong (Rest is one big bucket) |
| Effect on a solo top-tier entry | Can hand the item to a lower tier | **None** |
| Predictable? | Very — whole tiers, easy to count | Less — a decayed weighted number |
| Main risk | Overcorrects: "I'm T1 and I still can't win" | Undercorrects: too polite to fix anything |

**The short version:** Tier adjustment treats your hierarchy as a strong default that fairness
is allowed to override. Roll adjustment treats your hierarchy as inviolable and does what it can
inside it.

## 6. Worked example

Mid-raid. Tier count 3. A plate chest drops. Five people enter:

| Character | Owner | Tier | Owner's recent haul |
|---|---|---|---|
| Chop | Anna | T1 | nothing |
| Bonk | Dave | T1 | one item, 2 bosses ago |
| Smash | Steve | T3 | four items |
| Rusty | Priya | Rest | nothing |
| Grim | Tom | Rest | three items |

**Today (Off).** Anna and Dave roll it out at T1. Dave rolls 88, Anna rolls 41. **Dave wins.**
Anna having received nothing all night is not a factor.

**Tier adjustment.** Anna and Priya set the baseline at zero. Dave is 1 ahead, so T1 becomes T2.
Steve is 4 ahead, capped at 2, so T3 becomes `Rest −1`. Tom is 3 ahead, capped, so Rest becomes
`Rest −2`. Anna is now **alone in T1** and wins uncontested without rolling. Dave's 88 never
happens.

**Roll adjustment.** Tiers unchanged, so it is still Anna and Dave in T1. Dave's single win two
bosses ago has decayed to about 79% of its value, giving a 12-point penalty. Dave rolls
88 − 12 = 76, Anna rolls 41 − 0 = 41. **Dave still wins.**

Same board, three different answers. That gap is the decision.

## 7. Trying them properly

Both options will be built, behind one raid-leader setting with three values. Switching is a
dropdown, not a release — so we can run one for a fortnight and change our minds cheaply.

There is also an optional **shadow mode** the master looter can switch on, which shows in the
results what the *other* option would have done: *"under Roll adjustment, Bonk would have won
this."* It is off by default, because a permanent stream of near-misses would be miserable.
Turned on for a trial, it turns this argument from taste into evidence.

## 8. What neither option does

- **Neither looks at your gear.** An undergeared bot gets no priority for being undergeared —
  only for having received little *recently*. Weighting by how geared a character actually is
  is a real idea, and it is on the [roadmap](../ROADMAP.md); it needs gear data that only exists
  when someone remembers to run a manual scan while everyone stands in range, so it is not
  something to build a fairness rule on yet.
- **Neither knows what you need.** Winning an item you barely wanted costs you exactly as much
  as winning your best-in-slot.
- **Neither can be gamed by passing.** Passing earns no credit; only receiving costs you.
- **Neither touches your hierarchy.** You still set your ordering once and it still applies.

## 9. The decision

1. **Off** — keep today's rules. Every item independent, memory-free.
2. **Tier adjustment** — strong, decisive, can override the hierarchy.
3. **Roll adjustment** — gentle, continuous, never overrides the hierarchy.

Argue with this document. The parameters — 12 bosses, 14 days, 2 tiers, 15 points, 30 cap,
6-boss half-life — are all raid-leader settings, and every one of them is a guess that should be
challenged.

---

*Implementation: [spec 010](../specs/010-loot-ledger.md) (the ledger),
[spec 011](../specs/011-fairness-modes.md) (both options).*
