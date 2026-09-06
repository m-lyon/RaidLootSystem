# Spec 000 — Architecture

**Status:** agreed · **Applies to:** every other spec · **Read this first.**

This is the spec every implementing agent reads before touching anything else. It defines the
module layout, the pure-core boundary, the saved-variable schema, the comms protocol, and the
project conventions. Feature specs (001–009) assume everything here.

---

## 1. Target platform and its constraints

World of Warcraft **3.3.5a**, interface version **30300**, Lua **5.1**. AzerothCore server with
**mod-playerbots**. These constraints are load-bearing; several were discovered the hard way
and must not be quietly "modernised":

| Constraint | Consequence |
|---|---|
| `RegisterAddonMessagePrefix` does not exist (Cata+) | Do not call it. Filter on prefix inside the `CHAT_MSG_ADDON` handler. |
| Addon messages are capped at **255 bytes** including prefix, and are silently dropped when the server throttle trips | All comms go through a chunking, queueing transport. Never call `SendAddonMessage` directly outside `Modules/Comms.lua`. |
| `GetItemInfo` returns **localised** item class / subclass strings; there are no numeric `classID` / `subclassID` fields until 6.0 | Build a locale-independent index map at load from `GetAuctionItemClasses()` / `GetAuctionItemSubClasses(i)`. Never compare against hardcoded English strings. |
| `GetItemInfo` returns `nil` for an uncached item | Retry on a timer. There is no `GET_ITEM_INFO_RECEIVED` event in 3.3.5a. |
| Roster events are `RAID_ROSTER_UPDATE` and `PARTY_MEMBERS_CHANGED` | `GROUP_ROSTER_UPDATE` does not exist. |
| `GetMasterLootCandidate(index)` takes **one** argument in 3.3.5a | The two-argument `(slot, index)` form is a later API. |
| Item links contain `\|` characters | The comms protocol must not use `\|` as a delimiter, and must not transmit full links. Send item strings; rebuild links client-side. |
| Bind-on-pickup items are tradeable to kill-eligible players for **2 hours** (3.3.0 feature) | The trade fallback in spec 007 is legitimate but time-limited. |
| Bots do not run addons | Every bot interaction is `SendChatMessage(..., "WHISPER", nil, botName)`. Bots are never comms peers. |

## 2. The pure-core boundary

The heart of this addon is an algorithm: entries in, tiers and rolls and winners out. That
algorithm must be executable **outside WoW**, because the alternative is debugging loot
resolution live in a 25-man raid.

> **Rule:** no file under `Core/` may reference any WoW API, any global frame, or any
> `SavedVariables` table. Core takes plain Lua tables in and returns plain Lua tables out.
> Randomness is **injected**, never read from a global.

Everything that touches the game — frames, events, chat, comms, item lookups — lives in
`Modules/` or `UI/` and calls into `Core/`. Adapters in `Modules/` are responsible for turning
WoW data into the plain tables `Core/` expects.

CI enforces this with a grep over `Core/` for a denylist of WoW globals (spec 009).

## 3. File layout and load order

```
RaidLootSystem/
  RaidLootSystem.toc
  RaidLootSystem.lua          -- bootstrap, namespace, slash command dispatch
  Core/                       -- PURE LUA. No WoW API. Ever.
    Constants.lua             -- enums, protocol ops, defaults
    Util.lua                  -- table/string helpers
    Serialize.lua             -- protocol encode/decode, chunk split/join
    Tiers.lua                 -- hierarchy ordering -> tier assignment
    Eligibility.lua           -- (itemInfo, charInfo, config) -> bool, reason
    Resolve.lua               -- entries -> ordered winners + full roll record
    PriorityList.lua          -- Suicide Kings list: seed, suicide, restore     [010]
  Modules/
    Database.lua              -- SavedVariables load, defaults, migration
    Comms.lua                 -- addon-message transport: queue, chunk, throttle
    Roster.lua                -- claims, conflicts, raid presence
    ItemInfo.lua              -- WoW item lookups -> Core itemInfo tables
    LootDetect.lua            -- loot window scanning, batch candidate items
    Session.lua               -- HOST side: batch lifecycle, authority, resolution
    Client.lua                -- CLIENT side: batch state mirror, submissions
    Award.lua                 -- GiveMasterLoot, failures, trade fallback, auto-equip
    Pending.lua               -- undelivered items and their 2h countdown
    History.lua               -- record, retain, export
    PriorityList.lua          -- list storage, sync, SKLIST broadcast, verify   [010]
    Announce.lua              -- chat output, verbosity levels
    Simulate.lua              -- /rls simulate harness
  UI/
    Widgets.lua               -- shared frame factories
    RollWindow.lua            -- spec 005
    HostPanel.lua             -- spec 006
    HierarchyEditor.lua       -- spec 001
    HistoryBrowser.lua        -- spec 008
    Minimap.lua               -- LDB + LibDBIcon launcher
  Data/
    TierTokens.lua            -- token -> eligible classes
    ClassArmor.lua            -- class -> armour/weapon subclass permissions
  Libs/
    LibStub, CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0
  tests/
    run.lua                   -- standalone Lua runner
    fixtures/*.lua
```

`.toc` load order: `Libs` → `Core` (Constants, Util, Serialize, Tiers, Eligibility, Resolve,
PriorityList) → `Data` → `Modules` (Database first) → `UI` → `RaidLootSystem.lua` last.

`Data/` loads **after** `Core/`, so any `Core/` file reading `ns.Data` must do so inside a
function body, never at file scope. `Data/` files are plain Lua tables using the same
`local ADDON, ns = ...` idiom and are pure — the fixture runner loads them exactly like `Core/`
files (009 §2).

### Namespacing

```lua
local ADDON, ns = ...
ns.Resolve = {}
```

The **only** permitted globals are `RaidLootSystem` (the slash-command/debug entry point) and
the saved-variable tables named in the `.toc`. Everything else hangs off `ns`.

## 4. Saved variables

One account-wide table. There is no per-character table — a player's roster is theirs
regardless of which character they log in on.

```lua
RaidLootSystemDB = {
  schema   = 1,                      -- bumped by Database.lua migrations

  roster = {
    order = { "Steve", "Sneaky", "Smash", "Locky" },   -- hierarchy, index 1 = highest
    chars = {
      Steve  = { class = "MAGE",    isSelf = true  },  -- class is the enUS file name
      Sneaky = { class = "ROGUE",   isSelf = false },
    },
  },

  settings = {                       -- per-player preferences
    eligibilityFilter = true,
    autoEquipWinners  = true,
    verbosity         = "SUMMARY",   -- OFF | SUMMARY | VERBOSE (host only, but stored by all)
    minimap           = { hide = false, minimapPos = 220 },
    windows           = {},          -- frame positions
  },

  host = {                           -- used only when this client is host
    tierCount        = 3,            -- 0..5
    timerSeconds     = 180,          -- 15..300
    qualityThreshold = 4,            -- 3 = rare, 4 = epic
    lootMode         = "ROLL",       -- ROLL | SK; SK selectable only once seeded (010 §2)
  },

  priority = {                       -- Suicide Kings list. Every client stores it, not just
    version = 0,                     -- the host, because every client renders it. Spec 010 §9.
    seed    = 0,
    order   = {},                    -- character names, index 1 = highest priority
  },

  history = { --[[ see spec 008 ]] },
  pending = { --[[ see spec 007 ]] },

  scratch = {                        -- unsent roll-window ticks, so a /reload mid-batch
    sessionId = "",                  -- keeps them (005 §6). Reset when the batch changes.
    ticks     = {},                  -- itemIdx -> charName -> { override, star }
  },
}
```

`Database.lua` owns defaults and migration. Every other module reads through accessors, never
by touching the global directly — that keeps migration a single-file problem.

## 5. Comms protocol

**Prefix:** `RLS`. **Channel:** `RAID`, falling back to `PARTY`, then no-op when solo (except
under `/rls simulate`).

### Encoding

Full item links are never transmitted. Item **strings** are (`item:49623:0:0:0:0:0:0:0:0`);
receivers rebuild links via `ItemInfo`.

Because item strings contain `:` and links contain `|`, the delimiters are:

| Level | Delimiter |
|---|---|
| Top-level fields | `^` |
| List elements | `~` |
| Sub-fields within a list element | `=` |

`Core/Serialize.lua` owns encode/decode and is fixture-tested. No module builds a wire string
by hand.

### Envelope

Every message is:

```
<proto>^<op>^<msgId>^<seq>^<total>^<body>
```

`proto` is an integer (currently **1**). `msgId`/`seq`/`total` implement chunking; single-chunk
messages use `seq=1,total=1`. `Comms.lua` reassembles before dispatch and discards incomplete
message sets after 10 seconds.

Payload budget: **180 bytes** per chunk body. Outgoing messages sit in a queue drained on
`OnUpdate` at a maximum of **4 messages per second** to stay well under the server throttle.

### Operations

| Op | Direction | Body | Purpose |
|---|---|---|---|
| `HI` | any → all | `addonVersion` | Announce presence and version on load and on roster change |
| `ROSTER` | client → all | `name=class~name=class~…` (in hierarchy order) | Publish this player's claimed roster |
| `RREQ` | host → all | *(empty)* | Ask everyone to resend `ROSTER` |
| `OPEN` | host → all | `sessionId^tierCount^secondsLeft^item~item…` where item is `idx=itemString=count` | Open a batch |
| `SUBMIT` | client → host | `sessionId^entry~entry…` where entry is `itemIdx=charName=overrideFlag=star` | Submit or revise entries (`star` is the SK priority pick, 010 §7) |
| `STATE` | host → all | `sessionId^submittedNames~…^entry~entry…` where entry is `itemIdx=charName=owner=tier` | Authoritative aggregate; drives the live open view |
| `RESULT` | host → all | `sessionId^result~result…` where result is `itemIdx=winner=tier=roll=outcome` | Resolved batch |
| `ROLLS` | host → all | `sessionId^roll~roll…` where roll is `itemIdx=charName=tier=roll=listIdx=status=rerolls` | Full roll record for the results table; `roll` is 0 under SK, `listIdx` is 0 under ROLL. `status` is empty for a rolled entry, `NC` not consulted, `WD` withdrawn (010 §7); `rerolls` is the tie re-roll list joined with `+`. Both exist so the results table can show a not-consulted entry as such and a re-roll inline (005 §5) — neither is derivable from the roll value |
| `ABORT` | host → all | `sessionId^reasonCode` | Batch cancelled |
| `CFG` | host → all | `tierCount^timerSeconds^lootMode` | Settings changed between batches |
| `SKLIST` | host → all | `version^seed^name~name…` | The authoritative priority list, sent immediately after `OPEN` and on request (010 §8) |
| `SYNC` | client → host | `sessionId` | Request a resend of `OPEN` + `STATE` |

**`secondsLeft`, not `endsAt`.** The host's `endsAt` is built on the client clock, which
counts from that client's own start, so an absolute deadline means nothing on another machine.
The wire carries the seconds remaining and each client adds them to its own clock. A resync
mid-batch (002 §10) therefore lands a late arrival on the same deadline as everyone else.

### Authority rules

1. **The host is whoever currently holds master looter.** Derived from `GetLootMethod()` and
   the `isML` flag in `GetRaidRosterInfo`, re-evaluated on `PARTY_LOOT_METHOD_CHANGED`,
   `RAID_ROSTER_UPDATE` and `PARTY_MEMBERS_CHANGED`.
2. **Clients hard-reject** `OPEN`, `STATE`, `RESULT`, `ROLLS`, `ABORT` and `CFG` from any sender
   who is not the current master looter. Log and drop; do not render.
3. **Clients never trust each other.** A client's own submission is provisional until it comes
   back in a host `STATE`. The live open view renders host `STATE` exclusively, never locally
   observed `SUBMIT` traffic.
4. **The host is the only announcer.** Clients never write to raid chat.
5. **Version skew:** a message whose `proto` differs from ours is dropped, and the user is
   warned **once per session per sender**, not per message.

## 6. Tier model

Canonical throughout the codebase:

- Tiers are integers. **1 is the highest priority.**
- With tier count `N`, hierarchy positions `1..N` map to tiers `1..N`.
- Every position `> N` maps to tier `N+1`, the **Rest** tier.
- `N = 0` means every character is tier 1 — a flat roll.
- A character not present in the player's `roster.order` has no tier and cannot be entered.

`Core/Tiers.lua` is the single implementation. Nothing else derives a tier.

## 7. Randomness

`Core/Resolve.lua` accepts an `rng` function as a parameter — `rng(1, 100)`. Production passes
a wrapper around `math.random`; tests pass a deterministic sequence. There is no `math.random`
call anywhere in `Core/`.

Seed `math.randomseed(time())` exactly once, in `RaidLootSystem.lua` at load.

## 8. Conventions

- **Naming:** `PascalCase` for modules and functions, `camelCase` for locals and fields,
  `SCREAMING_CASE` for constants in `Core/Constants.lua`.
- **No XML.** Frames are created in Lua via `CreateFrame`. It keeps diffs reviewable.
- **English only.** No locale layer in v1; strings live next to their use site.
- **Errors are surfaced, never swallowed.** A failed award, a dropped message set, or a version
  mismatch produces a visible message. Silent failure in a loot addon costs people items.
- **Every user-visible action that cannot be undone gets a confirmation step** — awarding loot,
  clearing history, overwriting a roster on import.

## 9. Versioning and process

- Semantic versioning in the `.toc` (`## Version:`), starting at `0.1.0`, staying on `0.x`
  until the addon has survived a real raid night.
- Feature branches, PRs into `main`.
- Commit subjects reference the spec they implement: `spec 003: tie re-roll loop`.
- A spec is only "done" when its acceptance criteria are demonstrable via `/rls simulate` or a
  fixture test.
