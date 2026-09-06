# Spec 002 — Session protocol

**Modules:** `Modules/Session.lua` (host), `Modules/Client.lua` (client), `Modules/Comms.lua`
**Depends on:** 000, 001
**Player-facing description:** DESIGN §3

---

## 1. Scope

The lifecycle of a **batch**: opening it, collecting submissions, keeping every client's view in
sync, closing it, and aborting it. Who is allowed to do what, and what happens when the network
or the raid misbehaves.

**Out of scope:** which items go into a batch (004), how a winner is computed (003), what the
windows look like (005, 006).

## 2. What a batch is

One batch covers **every rollable item from a single loot source**, resolved as one round. Six
epics off a boss is one batch with six columns, not six sequential rolls. This is the single
biggest pacing difference from RaidRoll and it is cheap because the items don't interact —
resolution runs independently per item.

```lua
session = {
  id         = "<hostName>-<timestamp>",  -- globally unique, human-debuggable
  host       = "Steve",
  tierCount  = 3,                          -- frozen at open
  endsAt     = <GetTime() + timerSeconds>,  -- local; the wire carries seconds left
  items      = { { idx = 1, itemString = "item:49623:...", count = 1, lootSlot = 3 }, ... },
  entries    = { [itemIdx] = { { char, owner, tier, override, submittedAt, revisedAt } } },
  submitted  = { [playerName] = true },
  state      = "OPEN" | "RESOLVING" | "CLOSED" | "ABORTED",
}
```

`lootSlot` is host-only and never transmitted — clients have no use for it and it would go
stale.

## 3. Host authority

The host is **whoever currently holds master looter**, re-derived on `PARTY_LOOT_METHOD_CHANGED`,
`RAID_ROSTER_UPDATE` and `PARTY_MEMBERS_CHANGED` (000 §5).

- Only the host may send `OPEN`, `STATE`, `RESULT`, `ROLLS`, `ABORT`, `CFG`, `RREQ`.
- Clients **drop** any of those ops arriving from a non-ML sender, and log it. There is no
  scenario in which a second client should be driving a batch.
- Only one batch may be open at a time. A second `OPEN` while one is live is a bug on the host;
  receiving clients replace their state and log a warning rather than trying to run two.

## 4. Opening

Preconditions, all checked before `OPEN` is sent:

1. Loot method is `master` and this client is the master looter.
2. At least one item passed the 004 filter.
3. No batch is currently open.

The host then freezes `tierCount` and `timerSeconds` from its settings, builds the item list,
persists the session locally, broadcasts `OPEN`, and announces to raid chat (spec 004 handles
the item list, `Announce` handles the message).

**Tier count is frozen at open.** A `CFG` change mid-batch is refused by the host UI with an
explanation; changes only take effect on the next batch.

## 5. Submitting

A client builds its entry set locally (005) and sends `SUBMIT` with the **complete** set for the
batch — submissions are idempotent replacements, not deltas. That makes revision trivial and
makes a dropped message self-healing on the next submit.

Host-side validation, applied to every entry in a `SUBMIT`:

| Check | Failure behaviour |
|---|---|
| Session id matches the open batch | Drop the whole message silently (stale client) |
| Batch state is `OPEN` | Drop, reply nothing — the timer has expired |
| `itemIdx` exists in the batch | Drop that entry |
| The character is in the sender's published roster (001) | Drop that entry |
| The character is not `contested` (001 §5) | Drop that entry |
| The character is present in the raid | Drop that entry |
| Eligibility passes, or `override` is set | Drop that entry unless overridden |
| No duplicate `(itemIdx, character)` pairs | Keep the first, drop the rest |

The host computes the **tier** for each accepted entry itself, from the sender's published
roster order and the frozen tier count. It never trusts a client-supplied tier.

Rejected entries are not silently swallowed: the accepted-entry count is readable in the next
`STATE`, and the submitting client compares it to what it sent and warns the player if they
differ. The count is **derived, not a new field** — every accepted entry in `STATE` carries its
owner, so a client counts its own and no protocol change is needed. Losing an entry to a validation quirk and finding out after the roll is exactly
the failure mode that destroys trust in a loot addon.

## 6. Timestamps and revision

- A player may re-submit freely while the batch is `OPEN`. Each `SUBMIT` fully replaces their
  previous entries.
- The host records `submittedAt` on first submission and `revisedAt` on each subsequent one.
- Both timestamps go into the history record (008). They are not shown in the roll window —
  they exist so that persistent last-second submitting is visible as a fact after the fact,
  rather than being mechanically prevented (DESIGN §10, ROADMAP: anti-sniping lockout).
- **Tier snapshot:** an entry's tier is fixed when the host accepts it. A player who reorders
  their hierarchy after submitting does not retroactively change a pending entry. Re-submitting
  re-derives it from the current order.

## 7. State broadcast

After every accepted `SUBMIT`, the host broadcasts `STATE` — the authoritative aggregate of who
has submitted and every accepted entry with owner and tier.

This is the **only** source for the live open view. Clients do not render their own
optimistically, and do not render other clients' `SUBMIT` traffic (which they cannot see
anyway, since `SUBMIT` is addressed to the host).

Rate limiting: with a handful of players revising, `STATE` traffic is small. The host coalesces
`STATE` sends on a 0.5s trailing timer so a burst of submissions produces one broadcast rather
than five.

## 8. Closing

A batch closes when:

- The timer expires, or
- The host force-closes early (typical once `submitted == expected`), or
- Every expected player has submitted **and** the host has "auto-close when all in" enabled
  (default on; a host who would rather let stragglers reconsider unticks it). The condition is
  re-tested when the group changes as well as on each submission, since a player leaving can be
  what empties the outstanding set.

On close: state goes `RESOLVING`, the host runs `Core/Resolve` per item (003), broadcasts
`RESULT` then `ROLLS`, announces per `Announce` verbosity, writes history (008), and moves to
the award flow (007). State goes `CLOSED` only once results are broadcast.

"Expected players" = raid members who have sent `HI` this session, i.e. are running a
compatible version. Players without the addon are not expected and never block a close.

## 9. Aborting

`ABORT` with a reason code, broadcast to everyone and shown in-window (not just in chat):

| Code | Trigger |
|---|---|
| `ML_CHANGED` | Master looter changed while a batch was open |
| `HOST_LEFT` | Host left the raid or logged out |
| `LOOT_GONE` | The loot source became invalid before resolution (004) |
| `EXPIRED` | Unresolved for 15 minutes |
| `MANUAL` | Host cancelled deliberately |

`ML_CHANGED` is the one reason that is **not broadcast**. A host that has just lost master
looter is no longer authoritative, and every client hard-rejects ops from a non-ML sender (§3),
so its `ABORT` would be dropped by the very clients that need it. Instead each client sees the
same `PARTY_LOOT_METHOD_CHANGED` event and ends its own mirror. That needs no message to
arrive, which is also what makes it correct when the old host has already disconnected.

**Aborted batches are never migrated to a new host.** A new host would have to reconstruct
entries it never received, and state-recovery bugs in a loot addon cost people items at the
worst possible moment. The new master looter restarts the batch from the item-link path (004).

Aborts are written to history with their reason, so a batch never simply vanishes.

If the host disconnects without sending `ABORT`, clients time out an open batch **60 seconds
after `endsAt`** with no `RESULT`, mark it aborted locally as `HOST_LEFT`, and log it.

## 10. Resync

A client that joins mid-batch, reloads its UI, or detects a gap sends `SYNC`. The host replies
with `OPEN` followed by `STATE`, addressed to the raid (simpler than whisper-targeting, and
harmless — the payload is already public).

Clients send `SYNC` at most once every 5 seconds.

## 11. Version handshake

`HI` is broadcast on load and on roster change, carrying the addon version. `proto` travels in
every message envelope.

- Mismatched `proto`: drop the message, warn the user **once per sender per session**.
- Matching `proto` but different addon version: no warning, but the host panel shows the version
  next to each player so drift is visible before it matters.

There is no proxying for players without the addon in v1 (ROADMAP).

## 12. Acceptance criteria

- Opening a batch with 6 items produces exactly one `OPEN`, correctly chunked, and all clients
  render 6 columns.
- A `SUBMIT` naming a character the sender has not published is rejected, and the submitting
  client warns about the count mismatch.
- Re-submitting replaces rather than appends: submitting `{A,B}` then `{A}` leaves one entry.
- Reordering the hierarchy after submitting does not change the tier the host recorded.
- Changing master looter mid-batch aborts with `ML_CHANGED` on every client, and the entries are
  written to history as aborted.
- A client that `/reload`s mid-batch recovers full state via `SYNC` within 5 seconds.
- A message from a non-ML sender claiming to be `OPEN` is dropped and logged, and no window
  appears.
- Under `/rls simulate`, a full open → submit → revise → close → resolve cycle runs with no
  live raid.
