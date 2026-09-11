# Spec 014 — The hierarchy lock

**Modules:** additions to `Modules/Roster.lua`, `Modules/Campaign.lua`, `Modules/Round.lua`,
`Modules/Client.lua`, `Modules/Announce.lua`, `Core/Serialize.lua`, `UI/HostPanel.lua`
**Depends on:** 001, 003, 006, 010, 012, 013

## 1. Scope

A campaign setting, **on by default**, that fixes each member's tier ranking once the campaign has
started. The host can turn it off, and turning it off is the escape hatch.

**Out of scope:**

- **Resolution is unchanged.** The lock decides what a member may submit, never how an item is
  awarded.
- **The priority list.** A list position is earned and spent by winning items (010 §3); this is
  about the hierarchy that picks the bucket, and nothing here touches the list.
- **A new wire op.** The setting rides in the two messages that already carry host settings.
- Locking anything else. The tier count, the timer and the loot mode stay the host's to change.

## 2. Why this exists

A tier is the first gate on every item under both loot modes: a lower tier is never consulted
while a higher one can still supply a winner (003 §5). So the cheapest way to take an item is not
to win it — it is to re-rank your characters the evening before the boss that drops what you want,
moving the character you want geared into T1 for one night.

Nothing stopped that. A hierarchy was editable at any moment, and the only visible trace was a
tier badge quietly reading differently than it had last week. The group's own rule — *"you rank
your characters, and you live with that ranking"* — existed in conversation and nowhere in the
addon.

This does not treat members as adversaries. It removes a temptation that a weekly raid puts in
front of everybody, and it makes the ranking mean what people already believed it meant.

## 3. When the lock is in force

Two conditions, both required:

| Condition | Why |
|---|---|
| `campaign.host.lockHierarchy` is on | The host setting, shared like the tier count and the loot mode. Default **on**. |
| The campaign **has started** — any history record names it | "Mid-campaign" has to mean something a client can answer alone. Every member records a history entry for every round it saw, tagged with the campaign, so a campaign with history has begun. Before the first round it is being set up and everyone arranges their characters freely: a lock that engaged at creation would make an on-by-default setting unusable. |

A member who joined late has no history for the campaign and is free until their first raid in it.
That is the same rule read from their side, and it is the right answer — they have not raided
under the ranking yet, so there is nothing to hold them to.

The **template** (012 §7) is never locked. It resolves nothing and seeds campaigns that have not
begun.

## 4. What the lock allows

`Roster.LockedChangeAllowed(storedOrder, incomingOrder)`, pure, in the `roster` suite.

An incoming ordering is allowed **only if the stored ordering is a prefix of it**. Appending is
the one permitted change.

| Change | Allowed | Why |
|---|---|---|
| Nothing changes | yes | A republish is not an edit, and republishing happens constantly. |
| A character appended at the end | **yes** | It lands in Rest, below everyone already ranked, so it jumps nobody — and without this a character rolled mid-campaign could never be brought in at all. |
| Two characters swapped | no | The change the lock exists to stop. |
| A character inserted above an existing one | no | It displaces everything under it. A re-rank however it is spelled. |
| A character removed | no | A reorder wearing a disguise: removing your T1 promotes every character below it by one. |

Case differences alone are not a re-rank, matching every other name comparison in the addon.

## 5. Where it is enforced

**Twice, deliberately.**

1. **In the editing member's own client.** `Roster.MoveIn` and the untick path of
   `Roster.SetIncludedIn` refuse and return a reason naming the campaign and saying the master
   looter can unlock it. Ticking a character *on* still works, by §4.
2. **On every client receiving a `ROSTER`.** The stored ordering stands, the change is refused,
   and a line says so in chat naming the member — never dropped silently (000 §2).

The second is not belt and braces. It is the only enforcement that holds against a member running
a build from before this spec, or one who edits the saved variables directly, and it is the copy
the host stamps entry tiers from. Enforcing only in the editor would be a suggestion.

This does mean a host's stored copy of a member's ordering can outrank an incoming one, which
narrows 013 §3's "`members` is a cache, never an authority". The narrowing is exactly this: while
a campaign is locked, the first submission is authoritative and later ones may only append.
Nothing else about it changes — no host screen edits a member's hierarchy, and `CFG` / `CSTATE`
still leave hierarchies alone.

## 6. The setting

`lockHierarchy` joins `host`, shared and announced like the tier count, the timer and the loot
mode, because it changes what members are allowed to do and a rule nobody was told about is not a
rule. The line says what it stops, not that a flag flipped:

> Hierarchies are locked - tier rankings are fixed for this campaign

| Decision | Reason |
|---|---|
| **Appended to the existing host fields, in `CFG` and the campaign codec** | Both already carry host settings, so no new op. A build from before this spec reads the fields it knows and ignores the new one. |
| **A missing field reads as locked** | The default is on, so a host running an older build does not silently unlock their raid. |
| **Assigned, never `or`-defaulted, on receipt** | `false` is a real value and the `and`/`or` idiom cannot carry one. An unlock would otherwise never reach anybody, which is the failure that matters most. |
| **Not frozen while a round is open**, unlike the other shared settings | Unlocking is the escape hatch for a member who ranked their characters wrong, and a host who needs it needs it now rather than after the boss. |

The host panel carries the tick box in **Raid settings**, with a line below it saying whether the
lock is in force *right now* — on before the first round changes nothing, and a host reading only
the tick box would believe otherwise.

## 7. Acceptance criteria

**Fixture (`roster` suite)**

- An unchanged ordering passes; a swap, an insert at the top, a removal and a truncation are each
  refused with a reason naming which.
- A character appended at the end is allowed.
- Case alone is not a re-rank.
- An empty stored ordering allows anything, so a first submission is unconstrained.

**Fixture (`serialize` suite)**

- `CFG` round-trips the lock on and, separately, off — `false` has to survive the trip, or a lock
  could only ever be turned on.
- A `CFG` body with only the four original fields decodes as locked.
- The campaign codec round-trips it inside the host element.

**Fixture (`announce` suite)**

- Locking and unlocking each produce a line saying what changed for members.

**`/rls simulate`**

- With the lock on and a round already run, a simulated member's re-ranked `ROSTER` leaves their
  stored ordering unchanged and prints the refusal.
- The same member appending a new character succeeds, and it lands in Rest.
- Unlocking mid-round succeeds where changing the tier count is refused.
