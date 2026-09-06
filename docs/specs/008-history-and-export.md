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

**Out of scope:** using history as a resolution input (ROADMAP: history-driven priority decay).

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
  source     = "Lord Marrowgar",         -- creature name, or "Item link" for the manual path
  host       = "Steve",

  settings   = {                          -- what the rules were AT THE TIME
    tierCount = 3, timerSeconds = 180, qualityThreshold = 4,
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

      entries = {                          -- EVERY entry, including not-consulted ones
        { char="Bonk", owner="Dave", tier=1, rolled=true, roll=91,
          rerolled={}, override=false,
          submittedAt=1757155230, revisedAt=nil },     -- host-only fields
        { char="Sneaky", owner="Steve", tier=2, rolled=false, reason="not consulted" },
      },

      awards = {
        { copy=1, char="Bonk", owner="Dave", tier=1, roll=91,
          delivery="DELIVERED",            -- DELIVERED | PENDING | FAILED | LOST | UNCLAIMED
          deliveryPath="MASTER_LOOT",      -- MASTER_LOOT | TRADE
          deliveredAt=1757155390 },
      },
    },
  },
}
```

Delivery state is **updated in place** when a pending item is later handed over, so the history
reflects what actually happened rather than what was intended at resolution time.

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
  `timestamp, zone, source, item, character, owner, tier, rolled, roll, awarded, delivery`

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
- The per-character summary for a bot lists exactly the items it was awarded, and nothing it
  merely rolled on.
