# Spec 011 — Fairness modes

**Modules:** `Core/Fairness.lua`, changes to `Core/Resolve.lua`
**Depends on:** 003, 010
**Player-facing description:** [proposal 001](../proposals/001-loot-fairness.md) §3–§6

---

## 1. Scope

The two consumers of the ledger, and how they attach to the resolution engine.

Everything here is **pure**. Both modes are small functions from a ledger plus a set of entries
to an adjustment per owner, and both are fixture-tested with a scripted rng exactly like the
rest of `Core/`.

**Out of scope:** deriving the ledger (010), displaying it (010 §11).

## 2. The setting

```lua
host.fairnessMode = "OFF" | "TIER" | "ROLL"
```

Changeable **between batches only**, like `tierCount`, and for the same reason: it changes the
rules everyone is playing by. Changing it broadcasts `CFG` and announces to raid chat. The value
in force at open is snapshotted into history (010 §9), so an old result stays explicable after
the group switches.

`OFF` is the default in code. Which mode the group actually runs is the decision proposal 001
exists to settle.

All three modes record identical history. Switching is a settings change, never a migration.

## 3. Shared adjustment basis

Both modes compare a player against **the other owners entering that specific item**, not
against the raid at large, and not against an absolute threshold.

```lua
Fairness.basis(ledger, entries) --> minCount, minWeight
```

The entrant with the lowest standing sets the baseline at zero; everyone else is measured as
excess above it.

> **Why relative and not absolute.** An absolute rule decays badly: deep into the window
> everybody has credits, so everybody is adjusted, and the hierarchy quietly flattens into noise
> at exactly the point people have stopped watching for it. Relative is self-normalising — there
> is always at least one entrant at their true tier and their true roll — and it is a direct
> transcription of the intent: the penalty is for being *ahead of the field*, not for having
> received anything at all.

A consequence to keep in mind when reading results: if every entrant on an item is equally far
ahead, no adjustment applies to any of them. That is correct, and it is why a quiet item can
resolve exactly as it would under `OFF`.

## 4. Mode `TIER` — tier adjustment

```lua
Fairness.tierDelta(ledger, entries, opts) --> deltaByOwner
```

```
minCount := min over entrant owners of ledger.standings[o].count      -- missing owner = 0
delta[o] := min(opts.tierCap, floor((count[o] − minCount) / opts.tierStep))
```

With defaults `tierStep = 1`, `tierCap = 2`: one item ahead is one tier down, two or more is two
tiers down.

The engine then bucket-walks on the **effective tier**:

```
effectiveTier(entry) := entry.tier + delta[entry.owner]
```

### Below Rest

Rest is `tierCount + 1` internally, and effective tiers beyond it are legal. Display mapping:

| Effective tier | Shown as |
|---|---|
| `t <= tierCount` | `T1` … `T5` |
| `t == tierCount + 1` | `Rest` |
| `t > tierCount + 1` | `Rest −1`, `Rest −2` |

Clamping at Rest was considered and rejected: Rest is the crowded bucket where the majority of
bot loot is actually decided, and an adjustment that could not reach into it would only ever
arbitrate between a handful of mains. **This makes DESIGN §2's "Rest is equal chance" true only
before adjustment**, and that amendment is owed in the same change as this spec.

### Ordering within a roster is preserved

Every entry an owner submits for an item is shifted by the same `delta`, so relative ordering
inside a roster is untouched. A player's mage still outranks their rogue; the whole roster moves
together.

### Interaction with `tierCount = 0`

A tier count of zero means every entry is tier 1 (001 §3). `TIER` still applies, producing a
flat roll with catch-up structure — the only structure present. This is defined behaviour, not
an accident: state it in the host panel's inline explanation.

## 5. Mode `ROLL` — roll adjustment

Tiers are **untouched**. Bucket walking is exactly as specified in 003 §5. The adjustment
reorders entries *inside* a bucket and can never move one across a tier boundary.

```lua
Fairness.penalty(ledger, entries, opts) --> penaltyByOwner
```

```
minWeight := min over entrant owners of ledger.standings[o].weight
excess[o] := weight[o] − minWeight
penalty[o] := 0                                   when ledger.reference <= 0
           := min(opts.penaltyCap,
                  round(excess[o] / ledger.reference × opts.penaltyPerItem))
```

`ledger.standings[o].weight` is already **decay-weighted** (010 §5); the decay itself lives in
the ledger derivation, not here. `ledger.reference` is the mean *undecayed* `gsValue` of credits
in the window — it is a unit of measure ("one average item"), not a standing.

The score a bucket sorts on:

```
score(entry) := entry.roll − penalty[entry.owner]
```

Penalties are **rounded to the nearest integer** before use, not just for display. Rolls are
integers; keeping scores integral keeps exact ties possible, which keeps the re-roll rule in §6
meaningful and keeps results readable.

Scores may fall below 1 or exceed 100. They are a sort key, not a roll — do not clamp them. Only
the penalty is capped.

### Why the reference is self-calibrating

`reference` is the mean item value in the current window, so `penaltyPerItem` is denominated in
*average items of the content we are actually running*. A fixed constant would need re-tuning
every content tier, and its failure mode is silent mis-scaling for months.

The consequence: in a window containing one enormous weapon and nine trinkets, the weapon is
worth several "items" of penalty. That is the intended behaviour and the entire reason this mode
weighs rather than counts.

## 6. Attachment to `Core/Resolve.lua`

```lua
opts.fairness = {
  mode = "TIER",                 -- OFF | TIER | ROLL; absent or OFF = no adjustment
  ledger = { standings = ..., reference = ... },   -- from Core/Ledger.build
  tierStep = 1, tierCap = 2,
  penaltyPerItem = 15, penaltyCap = 30,
}
```

`Resolve.item` gains two insertion points and no other change:

1. **Before bucketing** — under `TIER`, replace each entry's tier with its effective tier.
   Determinism (003 §4) sorts on the effective tier, not the base tier.
2. **After rolling a bucket** — under `ROLL`, subtract the owner's penalty and sort on `score`
   instead of `roll`.

Both are no-ops under `OFF`, and the existing fixtures must pass unchanged with `fairness`
absent. That is the guard against this spec quietly changing the base algorithm.

### Sequential batch threading

`Resolve.batch` iterates items in ascending `item.idx` and threads a **working copy** of the
ledger, per 010 §6:

```
working := deepcopy(opts.fairness.ledger)
for each item in ascending idx:
    result := Resolve.item(item, entries[item.idx], opts with working)
    for each award in result.awards:
        working.standings[award.owner].count  += 1
        working.standings[award.owner].weight += item.gsValue     -- batchesAgo = 0, no decay
```

- `item.gsValue` is supplied by `Modules/ItemInfo.lua` (010 §4) and is a new required field on
  `item` whenever `fairness.mode ~= "OFF"`.
- `working.reference` is **fixed for the whole batch**. Recomputing it mid-batch would make
  earlier and later items in one boss speak different units for no benefit.
- The input ledger is never mutated. `Resolve.batch` is still a pure function of its arguments.
- Multiple copies of a *single* item are awarded in one pass (003 §5) and do not penalise each
  other.

## 7. Results, comms and announcements

The authoritative adjustment is **carried in the result**, never re-derived by clients — a
client's ledger may legitimately differ (010 §7) and re-derivation would let two people read
different explanations of the same award.

`ROLLS` (000 §5) is extended:

| Op | Body |
|---|---|
| `ROLLS` | `sessionId^roll~roll…` where roll is `itemIdx=charName=baseTier=effTier=roll=penalty` |

Under `OFF`, `effTier == baseTier` and `penalty == 0`, so the shape is uniform across modes.

**Results table** (005 §5) shows the adjustment decomposed, never a bare final number:

```
TIER   Bonk    (Dave)   T1 -> T2    88
ROLL   Bonk    (Dave)   T1          88 - 12 = 76
```

**Chat** (`Modules/Announce.lua`, 006):

| Mode | Summary line |
|---|---|
| `OFF` | `[RLS] Botty [T2, 83] wins [Item]` |
| `TIER` | `[RLS] Botty [T2, 83] wins [Item]` — with `T1->T2` shown when adjusted |
| `ROLL` | `[RLS] Botty [T2, 83-12=71] wins [Item]` |

At `VERBOSE`, batch open also announces the mode and the top of the standings, because a rule
that silently moves people's odds should say so where everyone reads it.

## 8. Shadow mode

`host.shadowMode`, default `false`. When on, the host additionally resolves the batch under the
*other* mode and records the counterfactual.

**Implementation:** capture the sequence of values the injected `rng` produced during the real
resolution, then re-run `Resolve.batch` with a scripted rng replaying that exact sequence and
the other mode's `fairness` block. No change to the real path, no second randomness source.

**Honest caveat, which must appear in the tooltip:** because the tier structure differs between
modes, the replayed values land on different entries. The shadow is *a plausible outcome under
the same luck*, not a proof of what would have happened. Label it accordingly — `"Under Roll
adjustment: Bonk"` with the caveat on hover, not a bald counterfactual claim.

Shadow results are written to history under a `shadow` key and are excluded from the ledger,
from the results table by default, and from chat entirely. They exist to be read back after a
trial fortnight, not to be argued about live.

## 9. Acceptance criteria

Fixture cases with a scripted rng, all runnable outside WoW:

**Neutrality**

- Every existing 003 fixture passes unchanged with `opts.fairness` absent.
- `mode = "OFF"` with a populated ledger produces byte-identical output to `fairness` absent.
- All entrants equally ahead: no adjustment under either mode.

**TIER**

- Two T1 entrants, one owner 1 credit ahead: the ahead owner resolves at T2, the other wins
  uncontested and is the only entry with `rolled = true`.
- An owner 5 credits ahead with `tierCap = 2` drops exactly 2 tiers.
- A Rest entry adjusted downward is recorded at `tierCount + 2` and renders as `Rest -1`.
- An owner entering three characters has all three shifted by the same delta, preserving their
  relative order.
- `tierCount = 0` with an adjusted owner produces two buckets, not one.

**ROLL**

- Bucket membership is identical to `OFF` for the same entries — the adjustment never moves an
  entry between tiers.
- `reference = 0` (empty window) yields zero penalty for everyone and no division.
- An owner one reference-item ahead receives exactly `penaltyPerItem` points of penalty.
- An owner ten reference-items ahead receives exactly `penaltyCap`.
- A raw roll of 88 with a penalty of 12 sorts as 76, and both numbers survive into the record.
- A boundary tie on *scores* re-rolls the raw roll and re-applies the same penalty; the
  `rerolled` list records raw values (003 §6).

**Sequential batching**

- Four items, one owner winning item 1: their standing on items 2–4 is one credit and one
  `gsValue` higher than at open.
- Two copies of a single item awarded to the same owner do not penalise each other within that
  item.
- Reordering the input item list produces a different, but still deterministic, outcome — and
  the same input order always produces byte-identical output.
- `Resolve.batch` does not mutate the ledger passed in.

**Shadow**

- Shadow resolution consumes no additional rng draws beyond the replayed sequence.
- Shadow output never appears in `RESULT`, `ROLLS`, chat, or the ledger.
