# Spec 010 — Priority list (Suicide Kings)

**Modules:** `Core/PriorityList.lua`, `Modules/PriorityList.lua`, changes to `Core/Resolve.lua`
**Depends on:** 000, 001, 002, 003, 007, 008
**Player-facing description:** DESIGN §9, [proposal 001](../proposals/001-loot-fairness.md)

---

## 1. Scope

A persistent, ordered list of every claimed character. When several characters compete for an
item inside the same tier, the one highest on the list wins — no roll. The winner drops to the
bottom and everyone below moves up.

**Out of scope:** the tier model itself (001), eligibility (003 §8), delivery (007).

## 2. What changes, and how much

Suicide Kings is **deterministic**. Under `lootMode = "SK"` the resolution engine performs no
random draws at all: list indices are unique, so there are no ties and the re-roll loop in 003 §6
is unreachable.

This is a larger change to spec 003 than it first appears. `rng` survives — it seeds the list
(§5) and it still drives `lootMode = "ROLL"` — but under SK the sort key inside a tier bucket
becomes a list index, ascending, and the entire concept of a winning roll disappears from the
results table.

Two modes, both supported:

```lua
host.lootMode = "ROLL"   -- specs 003-009 exactly as written. Default.
                 "SK"    -- this spec.
```

`ROLL` is the default and `SK` becomes selectable only once a list exists (§5). That is
deliberate: there is no "SK mode with no list" state to define, test or explain, because it is
unreachable. `ROLL` also stays as the escape hatch when the list is in a bad state or the group
brings guests.

## 3. The list

An ordered array of **character** names — every character in every published roster, not one
entry per player.

```lua
priority = {
  version = 47,                   -- monotonic; every mutation bumps it
  seed    = 1757155200,           -- the seed the initial shuffle used (§5)
  order   = { "Chop", "Sneaky", "Steve", "Botty", ... },   -- index 1 = highest priority
}
```

**Characters, not players.** A player's roster does not share one position: their mage sinking
after a win leaves their rogue untouched.

> **Consequence, and it belongs in the player-facing doc.** Because a position is per character,
> entering an item costs that character its place but costs the *player* nothing elsewhere. At
> the player level, ticking everything remains free. Suicide Kings is often described as making
> entry a meaningful decision; in this variant that pressure exists per character only, and the
> documentation should not oversell it.

This is the opposite of the choice made for tier assignment, where the hierarchy is per player,
and the two are orthogonal on purpose: **the hierarchy decides which bucket you compete in, the
list decides who wins inside it.**

## 4. `Core/PriorityList.lua`

Pure. Plain tables in, plain tables out, randomness injected.

```lua
PriorityList.seed(chars, rng)                        --> order
PriorityList.indexOf(order, char)                    --> integer | nil
PriorityList.suicide(order, char, presentSet)        --> order', priorIndex
PriorityList.restore(order, char, index, presentSet) --> order'
PriorityList.addChar(order, char)                    --> order'
PriorityList.removeChar(order, char)                 --> order'
PriorityList.replay(seed, chars, events)             --> order      -- §9 verification
```

None of these mutate their arguments. All are fixture-tested.

## 5. Seeding

The list is created once, by a **random shuffle** of every claimed character, from an explicit
seed value.

Seeding by hierarchy or by gear was rejected. Suicide Kings' fairness is a property of
convergence, not of the starting point — any seed washes out within a tier's worth of raiding —
so the only thing a clever seed can achieve is to bake an argument into day one. Seeding by tier
would also double-count the hierarchy, which the tier gate already enforces.

**The seed is public and the shuffle is reproducible.** The seed value is broadcast, stored in
`priority.seed`, written to history, and shown in the host panel. *"The list was randomised"* is
a claim; *"here is the seed, run it yourself"* is a fact, and this is the single moment where the
system's legitimacy is established.

Seeding is what makes `lootMode = "SK"` selectable. The host panel surfaces it as one prompt:
*"Seed the priority list to enable Suicide Kings."* Re-seeding later is possible, confirmed,
announced and versioned (§10).

## 6. Suicide

On winning an item, a character moves to the bottom and everyone below moves up.

### Absent characters do not move

Characters not in the raid hold their **absolute index**. Only present characters rotate around
them.

```
present  := indices in `order` occupied by characters currently in the raid
winner   := the present index of the winning character
move the winner to the LAST present index
shift the intervening present characters up one
leave every absent character's index untouched
```

The naive version — remove the winner, append to the end — is shorter and quietly rewards
absence: a bot left at home for three weeks floats upward as everyone else wins things and comes
back near the top. In a bot raid that is not hypothetical; it is what happens to every bot
somebody did not bother to summon.

### A failed delivery restores the position

The list mutates when the award is made. Delivery is confirmed later (007), or is not.

When an award's `delivery` moves away from `DELIVERED`, the character is **restored to the index
it held immediately before that suicide**, the affected present characters shift back down, the
version bumps, and it is announced.

Leaving someone suicided for an item they never received is the worst bug this feature could
ship, and unlike the rest of the list's state it cannot be noticed by inspection — the list looks
perfectly normal. `priorIndex` is therefore recorded on every award (§8) rather than recomputed.

### Nothing else moves the list

An item nobody entered changes nothing. Entry here is opt-in, so an unbid item means nobody
wanted it — it stays "unclaimed — master looter's choice" exactly as under `ROLL`. The
half-suicide variant described in the wider Suicide Kings literature exists for systems where
everyone is automatically entered, and does not apply.

## 7. Resolution under `SK`

### Within one item

Tier gating is unchanged (003 §5). Buckets are walked in ascending tier; a lower tier is never
consulted while a higher one can supply a winner. Inside a bucket, entries sort by **list index
ascending** and the top `k` win. No rolls, no ties, no re-rolls.

> **The caveat that must appear in the player-facing doc.** Suicide Kings' promise is *"wait long
> enough, reach the top, and the next thing you want is yours."* Under strict tier gating that
> holds only **inside a tier bucket**. If Anna's main is the raid's only warrior, she takes every
> plate item at T1 forever, however many times she suicides. Classic Suicide Kings cannot produce
> that outcome; this variant can.
>
> What limits it: an uncontested win still suicides you. Anna keeps her uncontested plate but
> falls down the list and stops winning the *contested* items — tokens, weapons, trinkets. The
> list self-corrects where people are actually competing and is inert where nobody is.

### Across a batch

Two SK-only rules, neither of which applies under `ROLL`:

1. **One win per character per batch.** A character that wins is withdrawn from the remaining
   items in that batch.
2. **The priority pick.** Each character may star **one** of its ticked items. If it would win
   more than one, the star decides which.

Without (2), items resolve in loot-slot order, which is arbitrary: your mage ticks five things,
wins the junk ring that happened to occupy slot 1, and its entry on the weapon in slot 4
evaporates. People remember that for months.

**Algorithm** — a bounded fixed point, not a sequential pass:

```
loop:
    resolve every item independently against the list as frozen at batch open
    for each character winning more than one item:
        keep its starred item, or its lowest item index if unstarred
        withdraw its entries from the others
    if nothing was withdrawn: break
until no entries were withdrawn (bounded by the entry count)

apply suicides once per winning character, in (item index, copy) order
```

Each iteration strictly removes entries, so it terminates. The star therefore **costs nothing**:
it is consulted only when a character would genuinely have won several items, so starring the
wrong thing never loses you an item you would otherwise have had.

> **Why the list can be frozen for the batch.** Under rule (1) a winner is withdrawn from later
> items anyway, and removing one element from an ordered list preserves the relative order of
> every other element. So resolving against a frozen list and mutating it item by item produce
> **identical** results. Freezing is chosen because it is simpler to reason about and removes
> loot-slot order as a factor entirely.
>
> This supersedes the sequential-resolution rule that an earlier draft of this feature required.
> Items are still not independent — rules (1) and (2) couple them — but the coupling no longer
> depends on the order items happen to occupy on the corpse.

### Attachment to `Core/Resolve.lua`

```lua
opts.lootMode  = "SK"
opts.priority  = { Chop = 1, Sneaky = 2, ... }   -- name -> index, frozen at batch open
opts.stars     = { Chop = 4 }                    -- name -> starred itemIdx
```

Absent `opts.lootMode`, or `"ROLL"`, every existing 003 fixture must pass unchanged. That is the
guard against this spec quietly altering the base algorithm.

## 8. State, authority and sync

The list is order-sensitive shared state that must survive raids, relogs and host changes.

**Stored by everyone, with derivation as a repair tool.** Every client keeps `priority` in saved
variables and applies the same deterministic mutation on `RESULT`. The host broadcasts the
authoritative copy when a batch opens.

Pure derivation from history was considered and rejected. It is the right answer for an
append-only tally, but Suicide Kings degrades **catastrophically** rather than gracefully: one
missing batch permanently corrupts the order of everything after it, and does so silently.

New op, added to the 000 §5 table:

| Op | Direction | Body | Purpose |
|---|---|---|---|
| `SKLIST` | host → all | `version^seed^name~name~…` | The authoritative order, sent immediately after `OPEN` and on request |

- Sent **after** `OPEN`, never folded into it; `Comms.lua` chunks it like anything else.
- A client whose stored `version` differs from the host's replaces its copy wholesale and says so
  in the roll window. The host is authoritative; clients never merge.
- A client that has not received `SKLIST` shows positions as unknown rather than falling back to
  its own copy, which could show a player a position the host will not honour.
- `SYNC` (002 §10) resends `OPEN`, `SKLIST` and `STATE`.

Existing ops change:

| Op | Change |
|---|---|
| `SUBMIT` | entry becomes `itemIdx=charName=overrideFlag=star` |
| `ROLLS` | roll becomes `itemIdx=charName=tier=roll=listIdx`; `roll` is 0 under SK, `listIdx` is 0 under ROLL |
| `CFG` | `tierCount^timerSeconds^lootMode` |

**`/rls sk verify`** recomputes the list from `priority.seed` plus the chronological award events
in history and reports whether it matches the stored order. Drift becomes a number rather than an
argument. It reports; it never silently repairs.

## 9. Saved variables

Additions to the 000 §4 schema. `schema` bumps to `2`; the migration is additive.

```lua
host = {
  tierCount        = 3,
  timerSeconds     = 180,
  qualityThreshold = 4,
  lootMode         = "ROLL",     -- ROLL | SK; SK selectable only once seeded
},

priority = {                     -- account-wide, not host-only: every client keeps it
  version = 47,
  seed    = 1757155200,
  order   = { "Chop", "Sneaky", ... },
},
```

`priority` sits outside `host` because every client stores and renders it, not just whoever holds
master looter.

### History

Extends the 008 §3 record:

```lua
settings = { tierCount = 3, timerSeconds = 180, qualityThreshold = 4,
             lootMode = "SK" },

priorityAtOpen = { version = 47, order = { "Chop", "Sneaky", ... } },

items = { {
  itemLevel = 264, quality = 4, equipLoc = "INVTYPE_CHEST",   -- see below

  entries = { { char="Bonk", owner="Dave", tier=1, listIdx=3, star=true,
                won=false, withdrawn=false } },

  awards  = { { copy=1, char="Bonk", owner="Dave", tier=1, listIdx=3,
                priorIndex=3,                     -- for restore-on-failure (§6)
                delivery="DELIVERED", deliveryPath="MASTER_LOOT" } },
} },
```

`priorityAtOpen` makes a past result reconstructible without replaying every earlier record,
which turns a disputed award into a five-second answer.

**`itemLevel`, `quality` and `equipLoc` are logged on every item, under both modes.** Nothing in
v1 reads them. They are the exact inputs a GearScore-style item valuation needs (ROADMAP:
ledger-based fairness adjustment), they are a pure function's arguments rather than a derived
score — so a formula change recomputes correctly instead of leaving two incompatible vintages in
one log — and they are **not** recoverable later from `itemString` alone, because `GetItemInfo`
needs the item in the local cache and months on it will not be there.

## 10. Host panel

A **Priority list** section, added to 006 §3:

- **The list itself**, ordered, with each character's owner, class colour, a marker for the
  host's own characters, and absent characters visibly greyed.
- **Seed list** when none exists — the prompt that enables `SK`. Shows the seed value afterwards.
- **Reseed**, **manual reorder** (drag), and **manual suicide / restore** for any character.
- **Version and verification** — the current version, and a `verify` button running §8's replay.

Every manual action is confirmed, announced to raid chat, version-bumped and written to history.
A silent edit to a public priority list would end the group's trust in it immediately, and unlike
a mis-set tier count it is invisible after the fact.

## 11. Roll window

Under `SK`, added to 005:

- Each roster row shows its **list position** instead of a roll placeholder. Positions above the
  raid's median are visually distinct — the thing people want to know at a glance is *am I near
  the top*.
- **The star control** — one radio per character row, across the item columns, clearing any
  previous star for that character.
- The detail panel shows entrants ordered by list position, so the outcome is legible before
  submission. Under SK the result is fully determined at close, and pretending otherwise would
  be theatre.
- Results mode shows `position 3` in place of a roll, plus `-> bottom` on the winner, and marks
  entries `withdrawn (won [Item])` where rule (1) or the star removed them. An entry that
  silently vanished from the results table is indistinguishable from a bug.

## 12. Acceptance criteria

**Pure list operations**

- `seed` with a scripted rng produces a byte-identical order across runs.
- `suicide` moves the winner to the last **present** index; absent characters keep their absolute
  index; present characters between shift up exactly one.
- `suicide` on a list where the winner is already last is a no-op other than the version bump.
- `restore` after a `suicide` returns the list to its exact prior order.
- `addChar` appends; `removeChar` closes the gap; a removed and re-added character lands at the
  bottom, never at its old index.
- `replay(seed, chars, events)` reproduces the stored order for a 200-event history.

**Resolution**

- Every existing 003 fixture passes unchanged with `lootMode` absent and with `"ROLL"`.
- Under SK, `rng` is never called during resolution.
- Tier gating is unaffected: one T1 entry at list position 25 beats a Rest entry at position 1.
- Inside a bucket, the lowest list index wins, and `tiersConsulted` is unchanged.
- Two copies go to the two lowest list indices in the bucket, in order.
- A character winning item 1 is withdrawn from items 2-6 and recorded as `withdrawn`.
- A character that would win items 1 and 4 with a star on 4 takes 4, and item 1 goes to the next
  eligible entry — which is awarded, not left unclaimed.
- Starring an item a character would not have won changes nothing.
- The fixed point terminates on a batch of 6 items where every character enters every item.
- Frozen-list and item-by-item mutation produce identical awards for the same input.

**State**

- A `RESULT` applied by two clients independently yields the same order and version.
- A client one version behind replaces its list wholesale on `SKLIST`.
- An award flipped to `FAILED` restores the winner's index and bumps the version.
- `verify` detects a single transposed pair in a 25-character list.
- Seeding is refused when a list already exists, except via explicit reseed.
- `SK` cannot be selected while `priority.order` is empty.
