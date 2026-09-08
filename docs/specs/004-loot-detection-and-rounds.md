# Spec 004 — Loot detection, item classification and rounds

**Modules:** `Modules/LootDetect.lua`, `Modules/ItemInfo.lua`, `Data/TierTokens.lua`, `Data/ClassArmor.lua`
**Depends on:** 000
**Player-facing description:** DESIGN §4 "Who can be entered", §3

---

## 1. Scope

Deciding **which items become a round**, and turning a WoW item into the locale-independent
`itemInfo` table that `Core/Eligibility.lua` consumes.

**Out of scope:** the eligibility predicate itself (003 §8), round lifecycle (002).

## 2. Two ways a round starts

### Corpse path (primary)

On `LOOT_OPENED`, if this client is the master looter, scan the loot window:

```lua
for slot = 1, GetNumLootItems() do
    local link                        = GetLootSlotLink(slot)
    local _, name, quantity, quality  = GetLootSlotInfo(slot)
end
```

An item becomes a **round candidate** if all hold:

1. It has an item link (skip coin slots).
2. `quality >= host.qualityThreshold` (default 4, epic).
3. It is equippable — `itemInfo.equipLoc` is a real slot — **or** it is a recognised tier token
   (which is not equippable but is redeemable).

Everything else — gold, Emblems, crafting mats, quest items, BoE greens — is excluded from
auto-add but remains **manually addable** from the host panel (006). That covers Primordial
Saronite, patterns, mounts, and anything the classifier misjudges.

Duplicate stacks: two loot slots holding the same item id collapse into **one** round item with
`count = 2` (DESIGN §4, resolution in 003 §5). The host retains both `lootSlot` values for the
award step.

The host is prompted, not railroaded: the host panel lists the candidates with checkboxes and a
**Start roll** button. Auto-opening a round the instant a corpse is looted would fire on trash
and on other people's boss kills.

### Item-link path (secondary)

Any item link dropped onto the roll window, or `/rls roll <link>`, starts a round for that item.
This covers:

- Trash drops and world drops
- Items already sitting in someone's bags
- Re-running a round that was aborted
- Anything the corpse scan filtered out

Item-link rounds have **no `lootSlot`**, so the award step goes straight to the trade path
(007 §5) rather than `GiveMasterLoot`.

## 3. Loot source validity

A corpse-path round is bound to a loot source. The host tracks:

- `LOOT_CLOSED` — the window closed. Not fatal; slot indices survive and the window can be
  reopened on the same corpse.
- `LOOT_SLOT_CLEARED` — a slot was emptied. If it belonged to an open round and was not cleared
  by our own award, that item is dropped from the round with a visible notice.
- The loot source becoming unreachable (corpse despawned) — detected at award time when
  `GetNumLootItems()` no longer matches, or the item at `lootSlot` differs.

If **every** item in a round becomes invalid, the host aborts with `LOOT_GONE` (002 §9). If
some remain valid, the round continues with the survivors and announces what was lost.

The host panel shows a persistent **"loot still on corpse"** banner listing unresolved items,
because a 3-minute window is long enough to wander off and forget (DESIGN §5).

## 4. Building `itemInfo`

`Modules/ItemInfo.lua` is the only place WoW item data is read. It produces the plain table
described in 003 §8.

### The locale trap

`GetItemInfo` in 3.3.5a returns **localised** class and subclass strings and provides no numeric
ids. Comparing against hardcoded English is a bug waiting for a non-enUS client.

Build an index map once at load:

```lua
local classes = { GetAuctionItemClasses() }              -- localised, but ORDER is stable
for i = 1, #classes do
    local subs = { GetAuctionItemSubClasses(i) }         -- localised, order stable
end
```

The **positions** in these lists are locale-independent. Map localised string → (classIndex,
subClassIndex) → our own internal constants (`"PLATE"`, `"SWORD_2H"`, …). Every downstream
comparison uses the internal constant.

### Uncached items

`GetItemInfo` returns `nil` for an item the client has not cached, and 3.3.5a has no
`GET_ITEM_INFO_RECEIVED` event. Handle it with a retry:

- Ask for the item, and if it returns nil, retry on a 0.25s ticker up to 20 times.
- A round cannot open until every candidate has resolved, or has exhausted its retries.
- An item that never resolves is added as `special = true` (§6) rather than being dropped —
  losing an epic because the client had a cold cache would be unforgivable.

## 5. `Data/ClassArmor.lua`

Static permission tables, used because there is no API to ask "can this *other* character equip
this?" — and every bot is another character.

**Armour, at level 80:**

| Type | Classes |
|---|---|
| `CLOTH` | MAGE, PRIEST, WARLOCK |
| `LEATHER` | ROGUE, DRUID |
| `MAIL` | HUNTER, SHAMAN |
| `PLATE` | WARRIOR, PALADIN, DEATHKNIGHT |

Applied **only** when `equipLoc` is one of the eight armour slots (003 §8 check 6).

`SHIELD` is its own subclass: WARRIOR, PALADIN, SHAMAN.
Off-hand holdables: any class that can use an off-hand.
Relics — `IDOL` (DRUID), `LIBRAM` (PALADIN), `TOTEM` (SHAMAN), `SIGIL` (DEATHKNIGHT).

**Weapons:** a class → permitted weapon subclass table, covering one- and two-handed axes,
maces and swords, polearms, staves, daggers, fist weapons, wands, bows, guns, crossbows and
thrown.

> **Implementation note:** populate these tables against the server's own data rather than from
> memory — WotLK weapon-skill permissions have several counter-intuitive entries (Rogues cannot
> use axes; Druids can use two-handed maces and polearms but not swords). Verify each row before
> shipping. A wrong row silently makes an entire class ineligible for an entire weapon type, and
> the failure is invisible until someone can't roll on a drop.
>
> The **override flag** (003 §8) is the safety valve for anything these tables get wrong, which
> is another reason it must exist in v1.

## 6. `Data/TierTokens.lua`

A tier token is not equippable by anyone. A naive equip check therefore filters every roster out
of the single most contested drop in the game.

WotLK groups all set tokens into three names:

| Token | Classes |
|---|---|
| **Vanquisher** | DEATHKNIGHT, DRUID, MAGE, ROGUE |
| **Protector** | WARRIOR, HUNTER, SHAMAN |
| **Conqueror** | PALADIN, PRIEST, WARLOCK |

Detection is **by trailing word**: any item whose name ends in `Conqueror`, `Protector` or
`Vanquisher` maps to the corresponding class set. This is deliberately adjective-agnostic — it
covers every difficulty and every tier from T7 to T10 without needing to enumerate the naming
scheme, and it keeps working if the server adds custom tokens following the same convention.

Backing that up: an explicit `itemId → classes` override table, populated during implementation
by querying the server's item database. The override wins where both match. Do not attempt to
enumerate token item ids from memory.

### Special items

`special = true` disables the eligibility filter entirely, making the whole present roster
enterable. Set it when:

- The item has no `equipLoc` and is not a recognised token (mounts, patterns, mats, Primordial
  Saronite).
- Classification failed — an uncached item that exhausted its retries.
- The item is a recognised token whose class set is unknown.

Special items display a visible marker in the roll window so people know the filter is off and
they are responsible for judging their own eligibility.

## 7. Acceptance criteria

- Opening a corpse with 6 epics and 1 green as master looter lists exactly the 6 epics as
  candidates, with the green available via manual add.
- Two loot slots of the same item produce one round item with `count = 2`.
- Lowering the quality threshold to rare includes blues on the next corpse.
- A cloak reports `equipLoc = INVTYPE_CLOAK` and does **not** carry an enforced armour restriction.
- `Chestguard of the Lost Conqueror` (or any `… Conqueror`) classifies as
  `tokenClasses = {PALADIN, PRIEST, WARLOCK}`.
- A mount classifies as `special = true` and every present character is enterable.
- An item not in the client cache resolves within 5 seconds, or is added as `special`.
- Class/subclass mapping is asserted against index positions, with **zero** hardcoded English
  item-class strings anywhere in the codebase (grep-checkable).
- A corpse despawning mid-round aborts with `LOOT_GONE` and writes to history.
- Dropping an item link on the roll window opens a round with no `lootSlot` and routes to the
  trade path at award time.
