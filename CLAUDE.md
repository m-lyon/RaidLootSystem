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
- **`Modules/` load before `UI/`**, so a module must not capture `ns.Widgets` (or any other UI
  table) at file scope -- it is still nil there. `Modules/PriorityList.lua` draws the host
  panel's priority section and resolves it in `Init` instead.
- **`math.randomseed` does not exist** in 3.3.5a either -- the client seeds its own RNG at
  startup. `math.random` is fine; guard any seeding call. Spec 000 §7.
- **`GetMasterLootCandidate(index)` takes one argument** in 3.3.5a, not two.
- **No screen asks the player to type or pick a class.** A typed class cannot be checked, and a
  wrong one silently filters a character off items they could have used. Class comes from the
  group, a published roster, or the guild roster, and an add whose class nothing knows is
  refused. Spec 001 §4.
- **A tier token is equippable by nobody.** Any candidate or eligibility test that leads with
  "is it equippable" filters the whole raid off the most contested drop in the game. The token
  check runs first, and it runs on the *name*, so a cold item cache does not lose it. Spec 004
  §6.
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
  one missing round silently corrupts every later position. `verify` replays history to *detect*
  drift; it never repairs. Spec 010 §8.
- **Seeding the priority list turns `SK` on, it does not merely unlock it.** `Priority.Seed`
  finishes with `Round.ChangeSetting("lootMode", "SK")`. A seeded list left on `ROLL` is
  indistinguishable on screen from a seeded list on `SK`, and the only symptom is that no winner
  ever moves. Spec 010 §5.
- **The open announcement leads with the loot mode**, "Rolling:" or "SK:". It is the host's own
  read-back that the mode is what they think it is. Chat abbreviates; panels and dialogs spell
  "Suicide Kings" out. Spec 006 §4.
- **Under `SK` the resolution engine calls `rng` zero times.** There are no ties to break; the
  003 §6 re-roll path is unreachable and should assert rather than sit there as dead code.
- **A failed delivery restores the winner's list position** from the recorded `priorIndex`.
  Never recompute it — by then the list has moved. Spec 010 §6.
- **Absent characters hold their absolute index.** The naive remove-and-append rewards not
  showing up. Spec 010 §6.
- **SK rounds are a fixed point, not a sequential pass.** Loot-slot order must not decide who
  wins what; only the order suicides are applied in. Spec 010 §7.
- **`itemLevel` / `quality` / `equipLoc` are logged on every item under both modes.** Nothing in
  v1 reads them; they cannot be backfilled once the client cache is cold.
## Testing

`lua tests/run.lua` runs the pure-core fixture suites with no dependencies beyond a Lua 5.1
interpreter. `/rls simulate` exercises the full pipeline in-game with no raid. See
[`docs/specs/009-simulation-and-testing.md`](docs/specs/009-simulation-and-testing.md).

Add a fixture case for every bug fixed in `Core/`.

## Verify, don't recall

- **`Data/ClassArmor.lua`'s weapon table was checked in game on 2026-09-06** and
  `WEAPONS_VERIFIED` is `true`. [`Data/VERIFY.md`](Data/VERIFY.md) records what was confirmed,
  and the `eligibility` suite pins each line. A row that a raid night contradicts gets a fix, a
  fixture and a line in that table, in that order.
- **`Data/ItemClasses.lua`'s subclass order was checked in game on 2026-09-06** and
  `SUBCLASS_ORDER_VERIFIED` is `true`. `Data/VERIFY.md` records what was confirmed.
  `Modules/ItemInfo.lua` still refuses to map subclasses at all when the live and table list
  lengths disagree, so a future drift is loud and open, not silent.
- **`Data/TierTokens.lua`'s `TOKEN_IDS` is intentionally empty.** Detection is by trailing word.
  Add an id only for a token observed to be misclassified in game, with the link in a comment —
  a fabricated id silently routes a token to the wrong classes with no fallback behind it.
- **`GetGuildRosterInfo(i)`'s 11th return is the enUS class token** in 3.3.5a (the 5th is the
  localised display name). Read off ElvUI's 3.3.5a backport in this install, not confirmed in
  game. `Roster.GuildClassOf` validates what comes back against `C.CLASSES`, so a wrong position
  refuses the add rather than writing a bogus class -- but the position itself still wants a
  raid-night check.
- **The exact mod-playerbots `equip` command syntax** (spec 007) is still unconfirmed against
  the server build.
- **Blizzard's `StaticPopupDialogs` `button3` / `OnAlt` is unconfirmed on 3.3.5a.**
  `UI/Campaigns.lua`'s non-members warning uses it for "Open anyway" (deliberately not `button2`,
  so Escape cancels rather than opening the round). ElvUI uses `button3`/`OnAlt` but through its
  *own* popup system, so it is not evidence for Blizzard's. If `OnAlt` never fires, that button is
  inert -- Invite and Cancel still work, so a host is blocked rather than misled, but it wants a
  raid-night check. Fall back to a second confirmed dialog if it turns out unsupported.

## What is and isn't in the tree

Specs 001, 002, 003 and 004 are built. In the tree: `RaidLootSystem.toc`, `RaidLootSystem.lua`,
`Core/{Constants,Util,Serialize,Tiers,Eligibility,Resolve}.lua`,
`Modules/{Database,Comms,Roster,ItemInfo,LootDetect,Round,Client}.lua`,
`UI/{Widgets,HierarchyEditor,Minimap}.lua`, `Libs/`, `Data/`, and `tests/` with the `tiers`,
`serialize`, `roster`, `round`, `eligibility`, `resolve`, `iteminfo` and `lootdetect` suites
plus `tests/purity.sh`.

`Modules/{Round,Roster,ItemInfo,LootDetect}.lua` each have a pure half above a "WoW-facing"
divider; the fixture runner loads all four. Keep new pure logic above that line.

`Round.Open` is reachable now. Until the host panel (006) exists, `/rls loot`, `/rls start`
and `/rls roll <link>` are the seam that drives it.

Specs 005 through 008 and 010 are built too: `UI/{RollWindow,HostPanel,HistoryBrowser}.lua`,
`Modules/{Award,Pending,History,PriorityList,Announce}.lua`, `Core/PriorityList.lua`, with the
`rollwindow`, `announce`, `hostpanel`, `award`, `pending`, `history`, `priority` and `sk` suites.
The pure list operations are `ns.PriorityList` (Core); the stateful module is `ns.Priority`.

Spec 009's `Modules/Simulate.lua` is built too. Every module in spec 000 §3 now exists.

Spec 011 adds `UI/PriorityViewer.lua` beyond 000 §3: the read-only priority list every player
can open with `/rls sk`. Its row model is `PriorityList.viewRows` in `Core/`, and
`PriorityList.aboveMedian` is the single definition of the near-the-top rule --
`RollWindow.AboveMedian` delegates to it so the two screens cannot disagree.

**Spec 012 (campaigns) is built**, in the two commits it was specified to land in:

1. **The rename**, 012 §2. One loot source's roll is a `round` everywhere in code, wire
   and docs; `Modules/Session.lua` became `Modules/Round.lua` and specs 002 and 004 were renamed
   with it. No behavioural change.
2. **The feature** — `Modules/Campaign.lua`, `UI/Campaigns.lua`, `schema` 3 with no migration
   (defaults are rebuilt), the `CINV` op, and campaign ids on `HI` / `ROSTER` / `OPEN` / `SKLIST` /
   `CFG`, plus the `campaign` suite. `host` and `priority` no longer exist at the top level of the
   saved variables and live on each campaign; read them through `Campaign.Active()`, and read a
   client's own ordering through `Database.Hierarchy()` — `roster.order` is gone.

The rules that are easiest to get wrong when working on it, each with its spec section:

- **A campaign-bearing message is applied to the campaign it names, if you are a member of it;
  otherwise it is dropped and logged.** Exceptions are `CINV` and `OPEN` only. This one rule is
  what stops a foreign master looter's `SKLIST` from replacing your priority list and wiping its
  log — the bug the whole spec exists to fix. 012 §10.
- **A pending delivery carries its `campaignId`** and a restore-on-failure targets *that*
  campaign's list, never the active one. The 2-hour trade window routinely outlives a campaign
  switch, and restoring into the wrong list is invisible by inspection. 012 §14.
- **`roster.defaultHierarchy` resolves nothing.** It seeds new campaigns and is never consulted for
  a tier, an entry or an award. The ordering that counts lives on the campaign. 012 §7.
- **Joining is invitation-only and stores nothing on refusal.** No ambient detection, no
  ignore-list, no durations. Re-inviting is the whole recovery mechanism, and adding state to
  "remember" a refusal reintroduces every question that design removed. 012 §6.
- **`round` never means a tie re-roll iteration** — those stay `rerolls`. And some uses of
  "session" mean a *login* session (002 §11's once-per-sender warning); the §2 sweep left those
  alone. 012 §2.

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
