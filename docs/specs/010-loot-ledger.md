# Spec 010 — Loot ledger

**Modules:** `Core/Ledger.lua`, `Core/GearScore.lua`, `Modules/Ledger.lua`
**Depends on:** 000, 003, 004, 007, 008
**Player-facing description:** [proposal 001](../proposals/001-loot-fairness.md) §2

---

## 1. Scope

Recording, deriving, bounding, broadcasting and displaying **what each player's roster has
recently received**. Nothing here changes a roll outcome.

**Out of scope:** using the ledger to change outcomes — that is [011](011-fairness-modes.md).

## 2. Why this is separate from 011

The two fairness modes are each about thirty lines of pure arithmetic. Everything genuinely
risky lives here: a new comms op, a new saved-variable section, a derivation over history that
must agree across clients, and a delivery-state reversal path. Bundling them would bury the
dangerous half underneath the interesting half.

It is also **one ledger, two consumers**. The ledger is recorded and broadcast identically
regardless of which mode is active — including when the mode is `OFF`. Switching modes is
therefore a settings change, never a data migration, and history logged under one mode remains
fully meaningful under the other.

## 3. Definitions

| Term | Definition |
|---|---|
| **Award-bearing batch** | A batch with at least one award whose `delivery` is `DELIVERED` and whose item met the batch's `qualityThreshold`. Aborted, unclaimed and all-failed batches are not award-bearing. |
| **Window** | The most recent `ledgerBatches` award-bearing batches, excluding any older than `ledgerMaxDays`, and excluding any before `ledgerResetAt`. |
| **Credit** | One delivered, quality-passing award. Carries a `count` of 1 and a `gsValue`. |
| **Standing** | A player's `{ count, weight }` pair derived from the window. |

**The unit of account is the owning player, never the character.** A credit is attributed to
`award.owner`, not `award.char`. The reasoning is in proposal 001 §2 and it is load-bearing: a
per-character ledger would penalise a player's top-ranked character for being top-ranked, which
inverts the entire point of the hierarchy. Do not "improve" this into per-character accounting.

## 4. `Core/GearScore.lua` — item value

Pure. Produces the `gsValue` carried by every credit.

```lua
GearScore.item(itemLevel, quality, equipLoc) --> number    -- 0 when unscoreable
```

**It takes three scalars, not an item link.** PlayerbotManager's equivalent takes a link and
calls `GetItemInfo` itself; ours cannot, because `Core/` touches no WoW API (000 §3) and CI
greps for exactly that. `Modules/ItemInfo.lua` (004) already resolves items and must be extended
to carry `itemLevel` alongside the `quality` and `equipLoc` it produces today.

### Algorithm

Ported from `PlayerbotManager/PBM/PBM_GearScore.lua` so our numbers match the ones players
already see in PBM's UI:

1. Look up `slotMod` for `equipLoc`. No entry means unscoreable — return `0`.
2. Quality normalisation, in this order:
   - quality `5` (legendary) → `qualityScale = 1.3`, quality treated as `4`
   - quality `7` (heirloom) → quality treated as `3`, itemLevel forced to `187.05`
   - quality `0` or `1` → `qualityScale = 0.005`, quality treated as `2`
   - otherwise `qualityScale = 1`
3. Quality outside `2..4` after normalisation → return `0`.
4. Pick the formula set: `A` when `itemLevel > 120`, else `B`. Index it by normalised quality;
   a missing entry returns `0`.
5. `score = ((itemLevel − f.A) / f.B) × slotMod × SCALE × qualityScale`, floored, clamped at `0`.

Constants — `SCALE = 1.8618`, the `slotMod` table, and the two formula sets — are copied
verbatim from `PBM_Constants.lua:12–50`. **Copy, do not depend.** Style B's credibility rests on
every client computing the same number for the same item, and a runtime dependency on whether
another addon happens to be loaded, at what version, is precisely how that stops being true.
Record the source file and line range in a comment so drift is traceable.

> **Naming trap, worth writing down.** In PlayerbotManager's saved variables, `row.gs` holds
> **average item level** and `row.realGs` holds the GearScore
> (`PBM_Inspect.lua:151`). Anyone reading that DB will reach for `.gs` and get the wrong number.
> We do not read that DB at all — this note exists so nobody "helpfully" starts.

### Fixture pinning

The `gearscore` suite pins a spread of real WotLK items to exact expected scores — a 264
two-hander, a 264 chest, a 232 ring, a trinket, a cloak, a green, and an item with an
unscoreable `equipLoc`. If PBM retunes its formula, these tests are how we find out rather than
silently disagreeing with the number on someone's screen.

## 5. `Core/Ledger.lua` — derivation

Pure. Builds standings from history records.

```lua
Ledger.build(records, opts) --> ledger
```

```lua
opts = {
  now             = 1757155200,  -- REQUIRED, injected. Core/ never calls time().
  ledgerBatches   = 12,
  ledgerMaxDays   = 14,
  halfLifeBatches = 6,           -- 0 disables decay; every credit weighs its full gsValue
  resetAt         = 0,           -- ignore everything at or before this timestamp
  adjustments     = { Steve = { count = -1, weight = -450 } },   -- manual, §10
}

ledger = {
  standings = { Steve = { count = 3, weight = 1180.4 }, Anna = { count = 0, weight = 0 } },
  reference = 452.7,             -- mean UNDECAYED gsValue in the window; 0 when empty
  batchCount = 9,                -- award-bearing batches actually in the window
  batchIds   = { "Steve-1757141000", ... },   -- newest first; index − 1 = batchesAgo
}
```

`count` is a plain undecayed tally, consumed by mode `TIER`. `weight` is **decay-weighted**,
consumed by mode `ROLL`. Both are always computed, whatever the active mode — one ledger, two
consumers (§2), and a mode switch must not need a different derivation.

**Derivation rules:**

1. Discard records where `simulated == true` (009 §4). A simulation must never move a real
   ledger.
2. Discard records at or before `resetAt`, and records older than `ledgerMaxDays`.
3. Deduplicate by `sessionId`, keeping the record with `recordedAsHost == true` if both exist.
4. Keep award-bearing batches only (§3), newest first, take at most `ledgerBatches`.
5. For each award with `delivery == "DELIVERED"` and item quality ≥ that batch's
   `settings.qualityThreshold`, credit `award.owner`:
   - `count += 1`
   - `weight += gsValue × lambda ^ batchesAgo`
6. Apply `adjustments` last, clamping each standing at `0`.
7. `reference` is the arithmetic mean of the **undecayed** `gsValue` over all counted credits.
   It is a unit of measure — "what one average item is worth" — not a standing, so decay must
   not touch it. When the window holds no credits, `reference = 0` and 011 treats every roll
   adjustment as zero rather than dividing by it.

### Decay

```
lambda    = 0.5 ^ (1 / halfLifeBatches)        -- 6 batches -> 0.8909
batchesAgo = index of the credit's batch in batchIds, minus one
```

The most recent award-bearing batch is `batchesAgo = 0` and weighs its full value. With
`halfLifeBatches = 0`, `lambda = 1` and decay is disabled.

**Decay is per batch, not per hour.** A raid night and a fortnight-long break produce identical
decay if the same number of bosses fall between them. That is deliberate: the ledger measures
loot opportunities elapsed, not time elapsed, and an eight-boss night should move it further
than a two-boss night. The 14-day ceiling is the only wall-clock rule.

Every player present in the raid appears in `standings`, including those with zero credits.
Absent entries and zero entries must be indistinguishable to the consumer, and the only way to
guarantee that is to materialise the zeroes.

## 6. Sequential resolution within a batch

Awards made **earlier in the current batch** count against later items in the same batch.

This costs spec 003 §7's "items are fully independent" property, deliberately and with the
reasoning in proposal 001 §2: a boss dropping four epics is exactly where one roster taking
everything happens, and a ledger frozen at batch open is switched off at that moment.

What is preserved is **determinism**: items resolve in ascending `item.idx`, which is loot-slot
order, so the sequence of `rng` calls and the sequence of ledger updates are both fixed for a
given input. The result stays byte-reproducible and fixture-testable.

Within a *single* item, multiple copies are still awarded simultaneously from one pass over the
tiers (003 §5). Winning copy 1 does not penalise you for copy 2 of the same item.

`Resolve.batch` threads a **working copy** of the ledger through the items and never mutates its
input. See 011 §6.

## 7. Authority and broadcast

**The host's ledger is the one that decides items**, derived from the host's own local history.
Clients derive their own for display, and the two can legitimately differ — a stand-in host, or
someone who arrived at boss three, has seen a different set of batches.

That divergence is handled by making it **visible rather than silent**:

> The host broadcasts its complete ledger when a batch opens. The roll window renders the host's
> numbers, not local ones.

New op, added to the 000 §5 table:

| Op | Direction | Body | Purpose |
|---|---|---|---|
| `LEDGER` | host → all | `mode^reference^params^row~row…` where row is `player=count=weight` | The host's standings, sent immediately after `OPEN` |

- `params` is `ledgerBatches=ledgerMaxDays=tierStep=tierCap=penaltyPerItem=penaltyCap=halfLife`,
  so a client that missed a `CFG` still renders the same arithmetic the host will apply.
- `weight` is rounded to one decimal place on the wire.
- Sent **after** `OPEN`, never folded into it. `OPEN` is already close to the byte ceiling and
  the ledger scales with player count; `Comms.lua` chunks it like anything else.
- A client that has not received `LEDGER` renders adjustments as "unknown" and says so. It never
  falls back to its own numbers, which would show a player an adjustment the host will not apply.
- `SYNC` (002 §10) resends `OPEN`, `LEDGER` and `STATE`.

**The displayed adjustment during entry is an estimate.** It is computed from the ledger as of
batch open, and §6 means winning an early item in the same batch makes your real adjustment on
later items larger. The roll window must say this in one line rather than silently drifting from
the result.

Authoritative adjustments are carried in the results, not re-derived by clients — see 011 §7 for
the `ROLLS` extension.

## 8. Saved variables

Additions to the 000 §4 schema. `schema` bumps to `2`; `Database.lua` owns the migration, which
is purely additive and needs no data rewriting.

```lua
host = {
  tierCount        = 3,
  timerSeconds     = 180,
  qualityThreshold = 4,

  fairnessMode     = "OFF",      -- OFF | TIER | ROLL          (011)
  ledgerBatches    = 12,         -- 0..50
  ledgerMaxDays    = 14,         -- 0..90, 0 = no ceiling
  ledgerResetAt    = 0,          -- credits at or before this timestamp are ignored
  ledgerAdjust     = {},         -- player -> { count = n, weight = n }, manual overrides
  shadowMode       = false,      -- show what the other mode would have done (011 §8)

  tierStep         = 1,          -- TIER: items ahead per tier dropped
  tierCap          = 2,          -- TIER: maximum tiers dropped
  penaltyPerItem   = 15,         -- ROLL: roll points per reference-value item ahead
  penaltyCap       = 30,         -- ROLL: maximum roll points deducted
  halfLifeBatches  = 6,          -- ROLL: decay half-life, in award-bearing batches
}
```

The ledger itself is **never stored**. It is derived from `history` on demand, which means it
cannot go stale, cannot disagree with the history browser, and cannot survive a history prune as
an orphan. `ledgerResetAt` and `ledgerAdjust` are the only persisted ledger state.

Note the retention asymmetry: history keeps 500 batches / 90 days (008 §4), the ledger window
reads at most 12 / 14 days. The window is always a subset, so pruning can never truncate it.

## 9. History additions

Extends the 008 §3 record. Both fields are written regardless of `fairnessMode`, so the log
stays complete under `OFF` and the ledger remains derivable retroactively:

```lua
settings = {
  tierCount = 3, timerSeconds = 180, qualityThreshold = 4,
  fairnessMode = "TIER",                    -- mode in force at open
  fairnessParams = { tierStep=1, tierCap=2, penaltyPerItem=15,
                     penaltyCap=30, halfLifeBatches=6,
                     ledgerBatches=12, ledgerMaxDays=14 },
},

ledgerAtOpen = { Steve = { count=3, weight=1180.4 }, Anna = { count=0, weight=0 } },

items = { {
  awards = { {
    copy = 1, char = "Bonk", owner = "Dave", tier = 1, roll = 88,
    gsValue = 494,                          -- ALWAYS written, even under OFF
    delivery = "DELIVERED", deliveryPath = "MASTER_LOOT", deliveredAt = 1757155390,
  } },
} },
```

`ledgerAtOpen` makes a past result reconstructible without replaying every earlier record, which
is what turns a disputed award into a five-second answer.

**Delivery-state reversal is a ledger event.** 008 §3 already updates `delivery` in place; when
it moves away from `DELIVERED`, that credit stops counting on the next derivation automatically,
because derivation reads the current record. No separate reversal path exists, and none should
be added — an item you never received must not cost you priority.

## 10. Host panel

Added to 006 §3 as a **Loot ledger** section, visible whenever `fairnessMode ~= "OFF"` and
collapsed by default when it is:

- **Standings table** — every raid member with `count`, `weight`, and their current adjustment
  under the active mode. Sorted by standing descending, so who is ahead is the first thing read.
- **Window summary** — `9 of 12 bosses · oldest 4 days ago · reference 453 GS`.
- **Reset ledger** — sets `ledgerResetAt = time()`. Confirmed, announced to raid chat, and
  written to history as an event. Wipes nothing; only moves the floor.
- **Manual adjustment** — per-player `count` and `weight` deltas, for the cases a rule cannot
  see (an item traded on afterwards, a mis-award). Confirmed and announced.

Both escape hatches are announced because they change the rules mid-raid, and a silent
adjustment to a public fairness ledger is the single fastest way to lose the group's trust in
the whole feature.

## 11. Roll window

Added to 005 §3. Under `OFF`, none of this renders.

- Each roster row carries its **adjustment badge** for the selected item — `−1 tier` or `−12`.
- The detail panel shows every entrant's standing alongside their tier, so the field is legible
  before you commit.
- A one-line caveat under the panel: *"Adjustments shown are as of the start of this roll."*
- Results mode shows the adjustment applied, decomposed — never a bare final number. 011 §7.

## 12. Acceptance criteria

- `Ledger.build` with an empty record list returns zeroed standings for every named player,
  `reference = 0`, and does not error.
- A record marked `simulated = true` contributes nothing.
- A batch whose only award is `FAILED` is not award-bearing and does not consume a window slot.
- An award flipped from `DELIVERED` to `LOST` after the fact is absent from the next derivation,
  with no explicit reversal call.
- 13 award-bearing batches with `ledgerBatches = 12` uses the newest 12; `batchesAgo` of the
  newest is `0`.
- A credit 15 days old is excluded with `ledgerMaxDays = 14` and included with `0`.
- A single credit of 400 in the newest batch yields `weight = 400`; the same credit six batches
  back yields `200`; twelve batches back yields `100`.
- `halfLifeBatches = 0` yields `weight == count × gsValue` for a uniform window.
- `reference` is unaffected by `halfLifeBatches`.
- Two records with the same `sessionId`, one host and one client, contribute one set of credits.
- `ledgerResetAt` set to now yields empty standings while history is untouched.
- `GearScore.item` returns `0` for `INVTYPE_BODY`, for an unknown `equipLoc`, and for a quality
  outside `2..5` and `7`.
- Every pinned item in the `gearscore` fixture matches its expected score exactly.
- `LEDGER` round-trips through `Comms` chunking for a 25-player raid.
- `gsValue` is written to awards under `fairnessMode = "OFF"`.
- Introducing `time()` or `GetItemInfo` into `Core/Ledger.lua` or `Core/GearScore.lua` fails CI.
