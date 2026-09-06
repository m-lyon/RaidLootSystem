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
- **`OPEN` carries seconds remaining, not an absolute `endsAt`.** The client clock is per
  machine. Spec 000 §5.
- **An `ML_CHANGED` abort is never broadcast.** The old host is no longer authoritative, so
  every client would drop the message. Each client aborts on the loot-method event. Spec 002 §9.
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
- **The priority list is per character; the hierarchy is per player.** They are orthogonal on
  purpose: the hierarchy picks your bucket, the list decides who wins inside it. Spec 010 §3.
- **The priority list is stored, not derived.** Unlike a tally, it degrades catastrophically —
  one missing batch silently corrupts every later position. `verify` replays history to *detect*
  drift; it never repairs. Spec 010 §8.
- **Under `SK` the resolution engine calls `rng` zero times.** There are no ties to break; the
  003 §6 re-roll path is unreachable and should assert rather than sit there as dead code.
- **A failed delivery restores the winner's list position** from the recorded `priorIndex`.
  Never recompute it — by then the list has moved. Spec 010 §6.
- **Absent characters hold their absolute index.** The naive remove-and-append rewards not
  showing up. Spec 010 §6.
- **SK batches are a fixed point, not a sequential pass.** Loot-slot order must not decide who
  wins what; only the order suicides are applied in. Spec 010 §7.
- **`itemLevel` / `quality` / `equipLoc` are logged on every item under both modes.** Nothing in
  v1 reads them; they cannot be backfilled once the client cache is cold.

## Testing

`lua tests/run.lua` runs the pure-core fixture suites with no dependencies beyond a Lua 5.1
interpreter. `/rls simulate` exercises the full pipeline in-game with no raid. See
[`docs/specs/009-simulation-and-testing.md`](docs/specs/009-simulation-and-testing.md).

Add a fixture case for every bug fixed in `Core/`.

## Verify, don't recall

- **`Data/ClassArmor.lua` ships with `WEAPONS_VERIFIED = false`.** The weapon table was
  assembled from reference material and has not been checked in game.
  [`Data/VERIFY.md`](Data/VERIFY.md) lists the doubtful rows in priority order. Do not raise
  that flag without doing the checks.
- **`Data/TierTokens.lua`'s `TOKEN_IDS` is intentionally empty.** Detection is by trailing word.
  Add an id only for a token observed to be misclassified in game, with the link in a comment —
  a fabricated id silently routes a token to the wrong classes with no fallback behind it.
- **The exact mod-playerbots `equip` command syntax** (spec 007) is still unconfirmed against
  the server build.

## What is and isn't in the tree

Specs 001, 002 and 003 are built. In the tree: `RaidLootSystem.toc`, `RaidLootSystem.lua`,
`Core/{Constants,Util,Serialize,Tiers,Eligibility,Resolve}.lua`,
`Modules/{Database,Comms,Roster,Session,Client}.lua`,
`UI/{Widgets,HierarchyEditor,Minimap}.lua`, `Libs/`, `Data/`, and `tests/` with the `tiers`,
`serialize`, `roster`, `session`, `eligibility` and `resolve` suites plus `tests/purity.sh`.

`Modules/Session.lua` has a pure half above its "WoW-facing" divider, like `Roster.lua`; the
fixture runner loads both. Keep new pure logic above that line.

Spec 002 waits on 004 for its input: nothing calls `Session.Open` yet, because nothing builds
the item list.

`Core/Resolve.lua` carries spec 010's SK resolution path (010 §7) because it is the same code
path. The rest of 010 — `Core/PriorityList`, storage, sync, restore-on-failure — is not written.

Still to write: `Core/PriorityList.lua` and every other module in spec 000 §3. Add each new
file to the `.toc` in the load order given there.

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
