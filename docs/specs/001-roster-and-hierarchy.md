# Spec 001 — Roster and hierarchy

**Modules:** `Modules/Roster.lua`, `Core/Tiers.lua`, `UI/HierarchyEditor.lua`
**Depends on:** 000
**Player-facing description:** DESIGN §2

---

## 1. Scope

Declaring which characters a player owns, ordering them, deriving tiers from that ordering,
detecting ownership conflicts, and export/import. Everything about *who a player speaks for*.

**Out of scope:** entering characters into a roll (005), how tiers affect a result (003).

## 2. Data model

The roster is a single ordered list plus a lookup table (schema in 000 §4).

```lua
roster.order = { "Steve", "Sneaky", "Smash", "Locky" }   -- index 1 = highest priority
roster.chars = { Steve = { class = "MAGE", isSelf = true }, ... }
```

Invariants, enforced on every write:

1. `order` contains no duplicates.
2. Every name in `order` has an entry in `chars`, and vice versa.
3. Exactly zero or one character has `isSelf = true`.
4. Names are stored in the game's canonical capitalisation as returned by
   `GetRaidRosterInfo` / `UnitName`. Comparisons elsewhere are case-insensitive.
5. `order` may contain characters **not currently in the raid**. Presence is a runtime property,
   not a stored one — the ordering is a standing statement, not a raid-night snapshot.

## 3. Tier derivation — `Core/Tiers.lua`

Pure function. The single implementation of the tier rule in the codebase.

```lua
-- position: 1-based index into roster.order
-- tierCount: 0..5
-- returns: integer tier, 1 = highest
function Tiers.forPosition(position, tierCount)
```

| Condition | Result |
|---|---|
| `tierCount == 0` | always `1` (flat roll) |
| `position <= tierCount` | `position` |
| `position > tierCount` | `tierCount + 1` (the Rest tier) |

Helpers:

- `Tiers.label(tier, tierCount)` → `"T1"`, `"T2"`, … or `"Rest"` when `tier == tierCount + 1`
  (and `"Flat"` when `tierCount == 0`).
- `Tiers.bands(orderLength, tierCount)` → the tier for every position, for drawing the editor's
  band separators.

**Truncation is a view, never a mutation.** Lowering the tier count must not touch
`roster.order`. Raising it later restores the previous distinctions exactly.

## 4. Claiming characters

Three ways to add a character to your roster:

1. **Add target** — the currently targeted player.
2. **Add all in group** — bulk-add every raid/party member not already claimed by someone else.
   Skips anyone already in another player's published roster; reports how many were skipped and
   why.
3. **Manual entry** — type a name and pick a class, for characters not currently online.

`isSelf` is set automatically for `UnitName("player")` and cannot be set manually. The player's
own character is added on first run if the roster is empty.

Class is captured as the **enUS file name** (`"DEATHKNIGHT"`, `"MAGE"`, …) from
`UnitClass`/`GetRaidRosterInfo`, never the localised display string.

## 5. Publishing and conflicts

On login, on roster change, and on receiving `RREQ`, the client broadcasts `ROSTER` (000 §5)
carrying the full ordered list. The order is transmitted because other clients need it to
render tier badges in the results table.

`Modules/Roster.lua` maintains a **claim index**: character name → claiming player. A conflict
is two different players publishing the same character name.

**Conflict handling:**

- Never auto-resolve. The addon does not pick a winner.
- Both claimants keep their local roster untouched.
- The conflicted character is marked `contested` in the claim index.
- A contested character is **not enterable by anyone** until the conflict clears. This is
  deliberately strict: awarding loot on a disputed ownership claim is worse than a ten-second
  conversation.
- The host panel (006) surfaces contested characters prominently; the roll window (005) shows
  the affected rows disabled with reason `"contested — Steve and Dave both claim Sneaky"`.

**Unclaimed bots:** raid members present but in nobody's published roster. Listed as a warning
in the host panel. Not enterable in v1 (see ROADMAP: RL session-claiming).

## 6. Presence

A character is **present** if its name matches a current raid or party member. Recomputed on
`RAID_ROSTER_UPDATE` and `PARTY_MEMBERS_CHANGED`, and cached — this is queried once per
character per item when building the roll window grid, so it must not be an O(n) scan each
time.

Presence is a hard gate on entry (see 003 §3).

## 7. Hierarchy editor UI

A single window, opened from the minimap button or `/rls`.

**Layout:** one vertical list of the player's roster in order. Each row shows:

- Position number
- Class-coloured character name, with a "you" marker on `isSelf`
- Tier badge for the *current* tier count, or the client's stored default when not in a raid
- Presence dot (in raid / not in raid)
- A remove button

**Tier bands** are drawn as labelled separators between rows — a horizontal rule after position
1 labelled `T1`, after position 2 labelled `T2`, and a heavier rule at the Rest cut-off. This
is what makes the abstract ranking concrete, and it is the main reason the editor is a list
rather than a settings table.

**Reordering** is drag-and-drop on the row handle. PlayerbotManager implements exactly this
pattern in its Class/Raid/Group tabs; match its interaction feel. Keyboard fallback: up/down
buttons on the focused row.

**Live tier count.** When in a raid with an active host, the editor shows the raid's tier count
and redraws bands when it changes (`CFG`). Outside a raid it shows the client's own stored
default so the display is never blank.

**Editing during an open batch** is allowed, but the editor displays a warning that entries
already submitted are locked to the tiers they had at submit time (see 002 §6).

## 8. Export / import

Match PlayerbotManager's `PBM_ExportImport.lua` UX so it's already familiar: a button producing
a selectable text string, and a paste box to import.

- Format: the same `Core/Serialize.lua` encoding as `ROSTER`, prefixed with `RLS1:`.
- Import is **destructive** and therefore confirmed: "Replace your current roster of 9
  characters?" with a preview of the incoming list.
- Import validates every invariant in §2 and rejects the whole string on any failure rather than
  importing partially.

## 9. Acceptance criteria

- `Tiers.forPosition` matches the table in §3 for every combination of position 1–10 and tier
  count 0–5. Fixture test.
- Lowering the tier count from 5 to 2 and raising it back to 5 leaves `roster.order` byte-identical.
- Two clients publishing the same character name results in that character being non-enterable
  on **both** clients, with a visible reason.
- A character in `roster.order` but not in the raid renders with a "not present" dot and is not
  enterable.
- Export → wipe → import reproduces the roster exactly, including order and `isSelf`.
- Roster changes propagate to other clients without a reload.
