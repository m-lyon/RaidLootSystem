# Spec 007 — Award and delivery

**Modules:** `Modules/Award.lua`, `Modules/Pending.lua`
**Depends on:** 000, 002, 003, 004
**Player-facing description:** DESIGN §5

---

## 1. Scope

Getting the item from wherever it is into the winner's bags, confirming it arrived, telling a
bot to equip it, and tracking anything that ends up stuck in the host's bags.

**Out of scope:** deciding the winner (003), the UI the buttons live in (005 §5, 006).

## 2. Two delivery paths

| Path | When | Properties |
|---|---|---|
| **Master loot** *(primary)* | Corpse-path batch, loot source still valid, winner in range | One click. Item goes corpse → winner. Binds to the winner. **No deadline.** |
| **Trade** *(fallback)* | Item-link batches, despawned corpses, out-of-range winners, host wants to move on | Host holds the item. Binds to the **host**, tradeable to kill-eligible players for **2 hours**. |

The master-loot path is the default because it has no clock attached. The trade path is a fully
supported escape hatch, not an error state — but it starts a countdown, so it is always
accompanied by a visible warning and a `Pending` record.

## 3. Master-loot award

Triggered from the award control on the results row (005 §5), host only.

```
1. Confirm.                       -- irreversible; see §6
2. Verify the loot source:
     loot window open, GetNumLootItems() consistent,
     GetLootSlotLink(lootSlot) matches the batch item.
3. Find the candidate index:
     for i = 1, 40 do
         if GetMasterLootCandidate(i) == winnerName then idx = i end
     end
4. GiveMasterLoot(lootSlot, idx)
5. Watch for LOOT_SLOT_CLEARED on lootSlot, with a 3s timeout.
6. On success: record delivered, then §5 auto-equip.
   On failure:  §4.
```

`GetMasterLootCandidate` takes **one** argument in 3.3.5a (000 §1). The two-argument form is a
later API and will silently misbehave.

For duplicate drops, each copy has its own `lootSlot` and is awarded separately, in copy order.

## 4. Failure states

Every failure is named, visible, and retryable. Nothing is ever silently dropped — an item that
quietly fails to be awarded is an item nobody notices is missing until the raid has moved on.

| State | Cause | Presentation |
|---|---|---|
| `NOT_A_CANDIDATE` | Winner absent from the candidate list — out of ~100yd range, different zone/instance, or left the raid | *"Botty is out of range. Bring them closer and retry."* Retry button. |
| `SOURCE_INVALID` | Corpse despawned, loot window closed, slot no longer matches | *"The corpse is gone."* Offers the trade path if the item was already looted, otherwise marks the item lost and records it. |
| `SLOT_NOT_CLEARED` | `GiveMasterLoot` returned but the slot never cleared within 3s — commonly the winner's bags are full | *"Award didn't complete — check Botty's bags."* Retry button. |
| `NO_LOOT_METHOD` | Loot method changed away from master loot | Explains, and routes to the trade path. |
| `NOT_LOOTED` | The host's own `LootSlot` on the trade path never cleared the slot — bags full, or the bind confirmation cancelled | *"The item did not reach your bags."* Retry button. The pending record is only written once the slot clears, so a cancelled take leaves nothing behind. |
| `TRADE_EXPIRED` | The 2-hour window ran out, or the host abandoned the delivery | *"The two-hour trade window ran out; the item is bound to you."* Not retryable: a fresh pending record would only lie. |

Failed awards remain actionable in the results view and in the host panel's on-corpse banner
until they succeed, are abandoned, or the corpse is gone.

## 5. Trade path and pending deliveries

When the host takes the item into their own bags — deliberately, or because the corpse is about
to despawn — the item becomes soulbound to the host with a 2-hour tradeable flag.

`Modules/Pending.lua` records it immediately:

```lua
pending[n] = {
  itemString, winner, owner, sessionId, itemIdx,
  takenAt   = time(),          -- when it entered the host's bags
  expiresAt = takenAt + 7200,
  delivered = false,
}
```

Behaviour:

- Persisted in `RaidLootSystemDB.pending`, surviving `/reload` and logout.
- **Login reminder** whenever anything is outstanding, listing item, recipient and time left.
- A live countdown per item, turning amber under 30 minutes and red under 10.
- Expired entries are not deleted — they are marked `expired` and kept, because an item welded
  to the wrong character is exactly the kind of thing that needs to be visible afterwards.

**Which copy is in the bags.** A bag lookup by item id cannot tell "this copy was looted" from
"the host owns one of these anyway" or "copy 1 is already in my bags for its own trade". The
host records how many of each batch item it holds when the batch opens; a copy counts as taken
only when the bags hold more than that baseline plus what other pending records already
account for. Otherwise the copy is looted from the corpse.

This baseline applies to **corpse batches only**. An item-link batch has no corpse: the host
opened it on an item already in their bags, so that copy *is* the one being awarded and the
baseline is not charged against it. Other pending records still are, so two copies are never
promised to the same winner twice.

**Constraint worth stating explicitly:** the 2-hour flag only permits trading to characters who
were **eligible for that loot at kill time**. A bot summoned in after the boss died cannot
receive it even though it won the roll and is standing right there. When a trade is refused,
report this as a probable cause rather than a generic failure.

**Where the list lives:** the host panel carries a **Pending deliveries** section, and
`/rls pending` prints the same list numbered for `/rls deliver <n>`. The slash form exists
because the host panel is only reachable while holding master looter (006 §2), and a host who
handed it over still has to deliver what is in their bags.

**Delivering:** a **Deliver** button per pending item targets the recipient, opens trade, and
places the item. For a bot, follow with the whisper needed to make it accept
(PlayerbotManager's bot command set includes trade handling — see
`PlayerbotManager/PBM/PBM_Windows.lua:61`). Trade range is ~11 yards; check with
`CheckInteractDistance(unit, 2)` and say so when out of range rather than opening a doomed
trade window.

Mark `delivered` on `TRADE_ACCEPT_UPDATE` completion, and update history.

## 6. Confirmation

Awarding is irreversible on the master-loot path and near-irreversible on the trade path. Every
award is confirmed with a dialog naming **the item, the winner, and the path**:

> Give **[Deathbringer's Will]** to **Botty** (Dave)?
> — from the corpse, binds to Botty.

or

> Take **[Deathbringer's Will]** into your bags for **Botty** (Dave)?
> — binds to **you**, tradeable for 2 hours.

A misclick here hands a raid-defining item to the wrong character permanently, and the whole
system's credibility rests on that not happening.

## 7. Auto-equip

After a **confirmed successful delivery** to a bot, and only if `settings.autoEquipWinners` is
on (default on):

```lua
SendChatMessage("equip " .. itemLink, "WHISPER", nil, winnerName)
```

- Only for characters in the host's own roster with `isSelf = false`. Never whisper a real
  player, and never whisper another player's bot — that player's client handles their own.
- Never fires on a failed or pending delivery.
- Rate-limited through the same outgoing chat queue as announcements; six items means six
  whispers and they must not burst.
- The exact command syntax must be **verified against the server's mod-playerbots build during
  implementation**. `PBM_Windows.lua:61` establishes that `equip` is a supported bot command;
  confirm the argument form (item link vs item name) before shipping, and fail quietly with a
  logged warning rather than spamming a bot with commands it rejects.

## 8. Delivery state

Every awarded copy carries one of the states history records (008 §3). `AWAITING` is the state
between resolution and the host's click; it is kept distinct from `PENDING`, which means the
host holds the item for a trade, so a batch nobody awarded reads as exactly that afterwards.

| State | Meaning |
|---|---|
| `AWAITING` | Resolved, no award attempted yet |
| `DELIVERED` | In the winner's bags, by either path |
| `PENDING` | In the host's bags with the 2-hour trade flag; a `Pending` record exists |
| `FAILED` | The last attempt failed with a named reason (§4); retryable, except `TRADE_EXPIRED` |
| `LOST` | The corpse is gone and the item was never looted |
| `UNCLAIMED` | Nobody entered; master looter's choice |

A record's state is the host's and is not transmitted; clients see the host's award controls
only through the results view on the host's own screen.

## 9. Acceptance criteria

- Awarding a valid corpse-path win moves the item and clears the loot slot, and the results row
  shows delivered.
- Awarding to a winner standing 200 yards away produces `NOT_A_CANDIDATE` with a retry button,
  and retrying after they close the distance succeeds.
- Awarding with the winner's bags full produces `SLOT_NOT_CLEARED`, not a silent success.
- A duplicate drop awards both copies to two different characters, each from its own loot slot.
- Taking an item into the host's bags creates a pending record with a correct 2-hour expiry that
  survives `/reload` and logout.
- A pending item still outstanding at login produces a reminder naming item, recipient and
  remaining time.
- An expired pending item is retained and marked expired, not deleted.
- Every award path passes through a confirmation dialog naming item, winner and path.
- Auto-equip fires exactly once per successful bot delivery, never for real players, never for
  another player's bots, and never on failure.
- With auto-equip off, no whispers are sent at all.
