# RaidLootSystem — working notes for agents

A World of Warcraft **3.3.5a** (interface 30300, Lua 5.1) addon for raid loot distribution where
players each control several bots. AzerothCore + mod-playerbots.

## Read before writing code

1. [`docs/specs/000-architecture.md`](docs/specs/000-architecture.md) — module layout, pure-core
   boundary, saved-variable schema, comms protocol. **Non-negotiable; everything assumes it.**
2. The numbered spec for the feature you're implementing ([`docs/specs/`](docs/specs/)).
3. [`docs/DESIGN.md`](docs/DESIGN.md) for the player-facing intent behind a rule, and
   [`docs/proposals/`](docs/proposals/) for intent behind rules the group hasn't settled yet.

If a spec and the code disagree, the spec wins — fix the code, or change the spec in the same PR
with the reasoning.

## Rules that are easy to break by accident

- **`Core/` touches no WoW API.** No `CreateFrame`, no `GetItemInfo`, no `time()`, no
  `math.random`. Timestamps and randomness are passed in as parameters. CI greps for this.
- **No hardcoded English item-class strings.** `GetItemInfo` returns localised class/subclass
  names in 3.3.5a with no numeric ids; build the index map from `GetAuctionItemClasses()`.
  CI greps for this too.
- **`RegisterAddonMessagePrefix` does not exist** in 3.3.5a. Don't add it.
- **`GetMasterLootCandidate(index)` takes one argument** in 3.3.5a, not two.
- **Roster events are `RAID_ROSTER_UPDATE` / `PARTY_MEMBERS_CHANGED`**, not
  `GROUP_ROSTER_UPDATE`.
- **All addon messages go through `Modules/Comms.lua`** — 255-byte cap, silent server-side
  throttling, chunking and queueing are handled there. Never call `SendAddonMessage` elsewhere.
- **Item links contain `|`.** The wire protocol transmits item *strings*, and its delimiters are
  `^` / `~` / `=`.
- **Bots are not comms peers.** Bot interaction is always
  `SendChatMessage(cmd, "WHISPER", nil, botName)`.
- **Only the host writes to raid chat.** Clients never announce.
- **Nothing irreversible without a confirmation dialog** — awarding loot, clearing history,
  overwriting a roster on import.
- **Failures are surfaced, never swallowed.** A silently dropped entry or a silently failed award
  costs someone an item.
- **The loot ledger counts owning players, not characters.** Per-character accounting penalises
  a player's top-ranked character for being top-ranked, inverting the hierarchy. Spec 010 §3.
- **The ledger is derived, never cached.** It is recomputed from history on demand so a
  delivery that later fails stops counting with no reversal path. Spec 010 §8.
- **`gsValue` is written to every award even when `fairnessMode = "OFF"`.** A group that enables
  a mode later must find usable history waiting.
- **`Core/GearScore.lua` takes scalars, not an item link.** PlayerbotManager's version calls
  `GetItemInfo` itself; ours cannot. `Modules/ItemInfo.lua` does the lookup.
- **With fairness on, items in a batch are no longer independent** — spec 003 §7 changed.
  Resolution order (ascending `item.idx`) is load-bearing, not incidental.

## Testing

`lua tests/run.lua` runs the pure-core fixture suites with no dependencies beyond a Lua 5.1
interpreter. `/rls simulate` exercises the full pipeline in-game with no raid. See
[`docs/specs/009-simulation-and-testing.md`](docs/specs/009-simulation-and-testing.md).

Add a fixture case for every bug fixed in `Core/`.

## Verify, don't recall

Several data tables must be checked against the live server rather than written from memory —
getting them wrong silently makes a class ineligible for a whole item category:

- WotLK class → weapon-subclass permissions (`Data/ClassArmor.lua`)
- Tier token item ids (`Data/TierTokens.lua`) — the trailing-word match is the robust path
- The exact mod-playerbots `equip` command syntax
- GearScore constants (`Core/GearScore.lua`) — copied from
  `../PlayerbotManager/PBM/PBM_Constants.lua:12–50`, pinned by the `gearscore` fixture suite

**PlayerbotManager naming trap:** in `LichborneTrackerDB`, `row.gs` is **average item level**
and `row.realGs` is the GearScore (`PBM_Inspect.lua:151`). We don't read that DB — this note
exists so nobody starts.

## Conventions

- Semver in the `.toc`, `0.x` until it has survived a real raid night.
- Frames created in Lua, no XML.
- Commit subjects name the spec: `spec 003: tie re-roll loop`.
- English only; no locale layer.

## Related addons on this machine

Both are installed alongside and are useful reference, not dependencies:

- `../PlayerbotManager` — bot command patterns, drag-to-reorder rows, export/import UX
- `../RaidRoll` — prior art, including the `GiveMasterLoot` call at
  `RaidRoll_ExtraRollFrames.lua:803`
