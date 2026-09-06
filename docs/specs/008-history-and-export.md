# Spec 008 — History and export

**Modules:** `Modules/History.lua`, `UI/HistoryBrowser.lua`
**Depends on:** 000, 002, 003, 007
**Player-facing description:** DESIGN §8

---

## 1. Scope

Recording what happened, keeping it bounded, showing it, and getting it out of the game.

The log is deliberately **richer than v1 reads**. It is the raw material for anything built
later — priority decay, per-bot gearing statistics, attendance, sniping patterns — and once
people have a tier's worth of raiding logged you cannot retroactively add fields. Log
generously now; read simply now.

**Out of scope:** the priority list itself ([010](010-priority-list.md)). The list is stored
state, not derived from history — but history is what `verify` replays to prove the stored list
is correct, and the fields that makes possible are in §3.

## 2. Who records what

- **Every client** records the results it received. A player's log is their own view.
- **The host's copy is canonical** and is the only one containing host-only data: submission
  timestamps, rejected entries, loot slots, delivery outcomes.
- Records carry `recordedAsHost = true|false` so the two are distinguishable when someone pastes
  a log into Discord.

## 3. Record schema

One record per **batch**, not per item — items in a batch share a loot source and a settings
context, and splitting them loses that.

```lua
{
  sessionId  = "Steve-1757155200",
  recordedAsHost = true,
  timestamp  = 1757155200,               -- time() at batch open
  closedAt   = 1757155380,
  zone       = "Icecrown Citadel",
  source     = "Lord Marrowgar",         -- creature name, or "Item link" for the manual path.
                                         -- 3.3.5a has no loot-source API: this is the
                                         -- looter's dead target at LOOT_OPENED, or nil.
  host       = "Steve",

  settings   = {                          -- what the rules were AT THE TIME
    tierCount = 3, timerSeconds = 180, qualityThreshold = 4,
    lootMode  = "SK",                     -- ROLL | SK                    (010 §2)
  },

  priorityAtOpen = {                      -- the list when the batch opened (010 §9)
    version = 47, order = { "Chop", "Sneaky", "Steve", "Botty" },
  },

  raid = { "Steve", "Dave", "Anna" },     -- players running the addon, for attendance later

  outcome    = "RESOLVED",                -- RESOLVED | ABORTED
  abortReason = nil,                      -- ML_CHANGED | HOST_LEFT | LOOT_GONE | EXPIRED | MANUAL

  items = {
    {
      itemString = "item:49623:0:0:0:0:0:0:0:0",
      count      = 1,
      unclaimed  = false,
      degraded   = false,

      itemLevel  = 264,                    -- the three inputs an item valuation needs.
      quality    = 4,                      -- ALWAYS written, under both modes. Nothing in v1
      equipLoc   = "INVTYPE_CHEST",        -- reads them. See below.

      entries = {                          -- EVERY entry, including not-consulted ones
        { char="Bonk", owner="Dave", tier=1, listIdx=3, star=true,
          rolled=true, roll=91, rerolled={}, override=false,
          withdrawn=false,                 -- SK: removed by the one-win rule or a star
          submittedAt=1757155230, revisedAt=nil },     -- host-only fields
        { char="Sneaky", owner="Steve", tier=2, listIdx=9,
          rolled=false, reason="not consulted" },
      },

      awards = {
        { copy=1, char="Bonk", owner="Dave", tier=1, roll=91, listIdx=3,
          priorIndex=3,                    -- SK: index before the suicide, for restore (010 §6)
          delivery="DELIVERED",            -- AWAITING | DELIVERED | PENDING | FAILED | LOST | UNCLAIMED (007 §8)
          deliveryPath="MASTER_LOOT",      -- MASTER_LOOT | TRADE
          deliveredAt=1757155390 },
      },
    },
  },
}
```

Delivery state is **updated in place** when a pending item is later handed over, so the history
reflects what actually happened rather than what was intended at resolution time.

A client's record has no `submittedAt`/`revisedAt`, `lootSlot`, `star`, `override` or delivery
fields: none of those reach the wire. On the host's own machine only the host record is written;
the host's mirror of its own broadcast would otherwise duplicate the batch.

Under `SK` this update also **triggers a list restore** (010 §6): an award moving away from
`DELIVERED` returns the character to `priorIndex`. That is why `priorIndex` is recorded rather
than recomputed — by the time a delivery fails, the list has moved and the original position is
no longer derivable from it.

### Why `itemLevel`, `quality` and `equipLoc` are logged

Nothing in v1 reads them. They are the exact inputs a GearScore-style valuation takes (ROADMAP:
ledger-based fairness adjustment), and logging the *inputs* rather than a computed score means a
later formula change recomputes the whole history correctly instead of leaving two incompatible
vintages in one log.

They are also not recoverable afterwards. `itemString` gives an item id, but resolving it back to
an item level needs `GetItemInfo` and a warm client cache — months later, that cache is cold and
the answer is nil. This is the "log generously, read simply" rule doing real work: three integers
per item now, or a permanently unusable history later.

## 4. Retention

Bounded so the saved-variables file cannot grow without limit:

- Keep the most recent **500 batches** or **90 days**, whichever bites first.
- Prune on load, not continuously.
- Warn before pruning if the oldest records have never been exported.

Aborted batches are retained with their reason and their submitted entries. A batch never simply
vanishes — "we rolled and then nothing happened" must always be explicable afterwards.

## 5. History browser

A window listing batches newest-first: date, zone, source, item icons, and an outcome badge.

Expanding a batch shows each item with the same results table as 005 §5 — full entries, tiers,
rolls, re-rolls, not-consulted markers, awards and delivery state. One rendering component,
used in both places.

Filters: by character, by owning player, by item, by date range, and "my roster only".

A **per-character summary** — every item a character has won, with dates — because "what has
Botty actually got out of this raid tier" is the question people will ask most.

## 6. Export

Two formats, both to a selectable text box (the standard addon idiom, since a WoW client cannot
write files):

- **Plain text** — human-readable, for pasting into Discord. One line per award, with a batch
  header.
- **CSV** — one row per **entry**, not per award, so the data is analysable:
  `timestamp, zone, source, item, itemLevel, quality, equipLoc, character, owner, tier, listIdx,
  star, rolled, roll, withdrawn, awarded, delivery`

Export respects the browser's current filters, so "everything Botty won in ICC" is one action.

The addon never transmits history anywhere. Export is manual, local, and user-initiated.

## 7. Acceptance criteria

- A resolved batch produces exactly one record containing every item and every entry, including
  entries that were never rolled.
- The settings block captures the tier count in force at open, and is unaffected by later changes.
- An aborted batch is recorded with its reason and its submitted entries.
- A pending item delivered 40 minutes later updates the original record's delivery state in
  place; no second record is created.
- Loading with 501 batches prunes to 500, oldest first.
- Client and host records of the same batch are both present and distinguishable by
  `recordedAsHost`.
- CSV export of a 6-item batch with 20 entries produces 20 rows plus a header.
- `itemLevel`, `quality` and `equipLoc` are written under `lootMode = "ROLL"` too.
- `priorityAtOpen` captures the list version and order at open and is unaffected by later
  suicides.
- An award flipped from `DELIVERED` to `FAILED` under `SK` restores the character to
  `priorIndex` and bumps the list version.
- The per-character summary for a bot lists exactly the items it was awarded, and nothing it
  merely rolled on.
