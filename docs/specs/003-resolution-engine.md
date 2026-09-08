# Spec 003 — Resolution engine

**Modules:** `Core/Resolve.lua`, `Core/Eligibility.lua`, `Core/Tiers.lua`
**Depends on:** 000 (pure-core boundary), 001 (tier model)
**Player-facing description:** DESIGN §3 "Resolution", §4

---

## 1. Scope

The algorithm. Given a set of entries for one item, produce the winner or winners and a complete,
auditable record of how they were chosen.

This spec is separated from 002 for one reason: **it must be executable outside WoW.** Every
function here is pure — plain tables in, plain tables out, randomness injected. That is what
makes it fixture-testable in CI (009) instead of only testable in a live raid.

**Out of scope:** collecting entries (002), classifying items (004), displaying results (005).

## 2. Inputs

```lua
Resolve.item(item, entries, opts) --> result
```

```lua
item = {
  idx        = 1,
  itemString = "item:49623:0:0:0:0:0:0:0:0",
  count      = 1,               -- number of copies to award
}

entries = {
  { char = "Sneaky", owner = "Steve", tier = 2, override = false },
  { char = "Bonk",   owner = "Dave",  tier = 1, override = false },
  ...
}

opts = {
  rng       = function(lo, hi) return ... end,   -- REQUIRED. Injected.
  tierCount = 3,
  maxReroll = 10,
  lootMode  = "ROLL",           -- ROLL | SK. Absent = ROLL. See spec 010 §7.
  priority  = nil,              -- SK only: charName -> list index, frozen at round open
  stars     = nil,              -- SK only: charName -> starred itemIdx
}
```

Entries arriving here are already validated and eligible (002 §5). `Resolve` performs no
eligibility checks and no roster lookups — it does not know what a roster is.

## 3. Preconditions, asserted

1. Every entry has an integer `tier >= 1`.
2. No two entries share the same `char` for the same item. A character rolls once per item;
   this is guaranteed by 002 §5 and asserted here so a protocol bug surfaces loudly.
3. `item.count >= 1`.
4. `opts.rng` is a function.

Assertion failures raise. In production the host catches, aborts the round with a visible error,
and writes the failure to history — resolving a loot roll on corrupt input is worse than not
resolving it.

## 4. Determinism

Before any rolling, entries are sorted by `(tier asc, owner asc, char asc)`. This makes the
sequence of `rng` calls deterministic for a given input, which is what allows fixture tests to
assert exact outcomes against a scripted rng.

Under `lootMode = "SK"` there is nothing random to sequence — list indices are unique and the
outcome is a pure function of the input — but the sort is retained anyway, so the two modes share
one code path and one set of fixtures.

## 5. Algorithm

```
remaining := item.count
awards    := {}
record    := {}                        -- every entry, rolled or not

for tier := 1 .. maxTierPresent, ascending:
    bucket := entries with this tier
    if bucket is empty: continue
    if remaining == 0:
        record every entry in bucket as { rolled = false, reason = "not consulted" }
        continue

    ROLL: for each entry in bucket: entry.roll := rng(1, 100)
          sort bucket by roll descending (stable, §4 ordering as the tiebreak for sorting only)
    SK:   sort bucket by entry.listIdx ascending          -- unique, so total and tie-free

    k := min(remaining, #bucket)        -- how many can win from this bucket
    resolveBoundaryTies(bucket, k)      -- see §6

    award the top k entries
    remaining -= k
    record every entry in bucket as { rolled = true, roll = ..., rerolled = ... }

if #awards == 0: result.unclaimed := true
```

**Key properties this produces, all of which are player-visible promises:**

- A lower tier is never consulted while a higher tier can still supply a winner. One T1 entry
  beats twenty Rest entries, every time, regardless of rolls.
- With multiple copies, the tiers are walked in order and copies spill downward — one T1 entry
  and two copies means the T1 entry takes one and the whole T2 bucket rolls for the other.
- Entries in tiers that were never consulted are still **recorded**, marked as not rolled, so
  the results table can honestly show "T3 — not consulted" rather than omitting them.
- Two copies always go to two distinct characters (guaranteed by precondition 2). They may
  belong to the same owner if that owner's entries genuinely placed first and second.

## 6. Tie handling

A tie only matters if it changes who gets an award. Two entries tied for 4th place when there is
one copy is irrelevant noise; two entries tied for 1st place is the whole ballgame.

> **Rule:** re-roll a tie group **only when it spans the award boundary** — that is, when the
> group contains both position `k` and position `k+1` in the sorted bucket.

Procedure:

This section applies to `lootMode = "ROLL"` only. Under `SK` list indices are unique, so a tie is
impossible and this whole path is unreachable — assert that rather than leaving it as dead code
somebody later "fixes".

1. Identify the tie group straddling the boundary.
2. Re-roll `rng(1, 100)` for **only** those entries.
3. Re-sort and repeat until the boundary is unambiguous, or `maxReroll` iterations elapse.
4. On exhausting `maxReroll`, fall back to the deterministic §4 ordering, mark the result
   `degraded = true`, and record it. This is a guard against a pathological rng, not an expected
   path; it must be visible if it ever fires.

Each re-roll is recorded in the entry's `rerolled` list so the results table and chat can
show `"Botty and Sneaky tied on 83 — rerolling"` and the history preserves the full sequence.

Ties entirely above the boundary (all of them win) or entirely below it (none of them win) are
left alone.

## 7. Output

```lua
result = {
  itemIdx   = 1,
  unclaimed = false,
  degraded  = false,
  awards = {                                  -- ordered; index = copy number
    { char = "Bonk", owner = "Dave", tier = 1, roll = 91 },
  },
  record = {                                  -- EVERY entry, for the results table and history
    { char = "Bonk",   owner = "Dave",  tier = 1, listIdx = 3,
      rolled = true, roll = 91, rerolled = {} },
    { char = "Sneaky", owner = "Steve", tier = 2, listIdx = 9,
      rolled = false, reason = "not consulted" },
  },
  tiersConsulted = 1,
}
```

`listIdx` is `0` under `ROLL`; `roll` is `0` and `rerolled` empty under `SK`. Both fields are
always present so consumers need no mode-specific branching.

`Resolve.round(items, entriesByItem, opts)` applies `Resolve.item` across a round and returns a
list of results.

**Under `ROLL`, items are fully independent** — there is no cross-item interaction of any kind.

**Under `SK` they are coupled**, by two rules specified in 010 §7: a character that wins is
withdrawn from the round's remaining items, and its starred item decides which one it takes if it
would win several. `Resolve.round` implements this as a bounded fixed point over the whole round,
not a sequential pass, so **loot-slot order is not a factor in who wins what**. Only the order in
which suicides are subsequently applied depends on item index.

## 8. Eligibility — `Core/Eligibility.lua`

Also pure. Decides whether one character may be entered for one item.

```lua
Eligibility.check(itemInfo, charInfo, config) --> ok, reasonCode
```

`itemInfo` is produced by `Modules/ItemInfo.lua` (spec 004) and is already
locale-independent — this function never sees a localised string.

```lua
itemInfo = {
  equipLoc      = "INVTYPE_CHEST",   -- or nil
  armorSubclass = "PLATE",           -- nil when not armour
  weaponSubclass= "SWORD_2H",        -- nil when not a weapon
  tokenClasses  = { "PALADIN", "PRIEST", "WARLOCK" },  -- nil unless a tier token
  special       = false,             -- true = unclassifiable, filter disabled
  quality       = 4,
}
charInfo = { name = "Bonk", class = "WARRIOR", present = true, contested = false }
config   = { filterEnabled = true }
```

Order of checks, first failure wins:

| # | Check | Reason code |
|---|---|---|
| 1 | `charInfo.present` | `NOT_IN_RAID` |
| 2 | `not charInfo.contested` | `CONTESTED` |
| 3 | `itemInfo.special` → **pass immediately** | — |
| 4 | `config.filterEnabled` false → **pass immediately** | — |
| 5 | `tokenClasses` present → class must be in it | `WRONG_CLASS_TOKEN` |
| 6 | `armorSubclass` present **and** the slot is one of the eight armour slots → class must be permitted that armour type | `WRONG_ARMOR` |
| 7 | `weaponSubclass` present → class must be permitted that weapon type | `WRONG_WEAPON` |
| 8 | otherwise | pass |

**Check 6's slot condition is essential.** Cloaks, rings, necks and trinkets report an armour
subclass (`CLOTH` / `MISCELLANEOUS`) but are wearable by everyone. Only apply the armour-type
rule when `equipLoc` is head, shoulder, chest, wrist, hands, waist, legs or feet. Getting this
wrong makes every cloak in the game cloth-only, which is the kind of bug that looks like
malice.

Checks 1 and 2 are **not** overridable. Checks 5–7 are — the player's per-entry override flag
skips them, for off-spec and judgement calls (DESIGN §4).

Class permission tables live in `Data/ClassArmor.lua` (spec 004 §5).

## 9. Acceptance criteria

Fixture tests with a scripted rng, all runnable outside WoW:

- One T1 entry versus twenty Rest entries: T1 wins, and none of the Rest entries have `rolled = true`.
- Two copies, one T1 entry, three T2 entries: T1 takes copy 1; all three T2 entries roll; the
  highest takes copy 2.
- Two copies, five T1 entries: exactly the top two by roll are awarded; no lower tier is consulted.
- Boundary tie with one copy: the tied pair is re-rolled, the untied entries are not, and
  `rerolled` records the sequence.
- Non-boundary tie: no re-roll occurs.
- Zero entries: `unclaimed = true`, empty awards, empty record.
- `tierCount = 0`: every entry is tier 1 and it degenerates to a flat roll.
- An rng that always returns 50 with a boundary tie hits `maxReroll` and returns `degraded = true`
  rather than looping forever.
- Duplicate `char` in the entry list raises rather than double-awarding.
- Cloak eligibility: a `WARRIOR` passes for an `INVTYPE_CLOAK` reporting `CLOTH`.
- Token eligibility: `PALADIN` passes and `MAGE` fails for a Conqueror token.
- The same input with the same scripted rng produces byte-identical output across runs.
- Every case above passes identically with `opts.lootMode` absent and with `"ROLL"`.
- Under `lootMode = "SK"`, `opts.rng` is never called. The SK cases live in 010 §12.
