# Spec 006 — Host panel

**Modules:** `UI/HostPanel.lua`, `Modules/Announce.lua`
**Depends on:** 000, 001, 002, 004
**Player-facing description:** DESIGN §6

---

## 1. Scope

The master looter's control surface: raid settings, batch candidates, roster health, live
submission tracking, and the controls that open, close and abort a batch.

Separated from 005 because it has a different actor and different permissions. Every player uses
the roll window; one person uses this. Merging them would mean permission-gating half the
controls in the addon's busiest screen.

**Out of scope:** the award action itself (007), history (008).

## 2. Visibility

The panel is only reachable when this client **is the current master looter**. Losing master
looter closes it. It is never a "read-only view for everyone" — a second person watching host
controls they cannot use invites confusion about who is actually driving.

## 3. Sections

### Raid settings

| Setting | Control | Default | Range | When changeable |
|---|---|---|---|---|
| Tier count | Slider | 3 | 0–5 | Between batches only |
| Entry timer | Slider | 180s | 15–300s | Between batches only |
| Quality threshold | Dropdown | Epic | Rare / Epic | Any time |
| Chat verbosity | Dropdown | Summary | Off / Summary / Verbose | Any time |
| Auto-close when all in | Checkbox | Off | — | Any time |
| **Loot mode** | Dropdown | Roll | Roll / Suicide Kings | Between batches only |

Changing tier count, timer or loot mode broadcasts `CFG` and **announces to raid chat** — these
change the rules everyone is playing by, so they are never silent. All three controls are
disabled with an explanatory tooltip while a batch is open (002 §4).

A tier count of 0 shows an inline explanation: *"Flat roll — no priorities."* Under Suicide
Kings, extend it: *"No tiers — the priority list decides every item."*

**Suicide Kings is not selectable until the list is seeded** (010 §5). The dropdown entry is
disabled with the prompt *"Seed the priority list to enable Suicide Kings"*, linking to the
section below. This is why there is no half-configured state to explain: an empty list under SK
is unreachable rather than special-cased.

### Batch candidates

Populated on `LOOT_OPENED` (004 §2). Lists each candidate item with icon, link, quality, and a
`x2` badge for duplicates. Each has a checkbox, default ticked.

- **Add item** — accepts a dropped item link or a bag item, for anything the filter excluded.
- **Remove** — takes one item out of the list, whatever put it there: an item-link addition, a
  promoted skipped row, or a plain corpse row. Unticking excludes an item from the next batch
  but leaves the row; removing is for a row that should not be on offer at all. It stays out
  until the next corpse scan or an **Add item** on the same link.
- **Start roll** — opens the batch with the ticked items. Disabled with a reason when
  preconditions fail (not master loot, no items, batch already open).

**After a batch closes** its items are withdrawn from the list — they have been rolled for, and
leaving them there invites a second batch on loot already awarded. Anything the host left
unticked stays, so the section reads as what is still outstanding. An **abort** withdraws
nothing: the batch did not happen, and the host will want to start it again.

Nothing opens automatically. Auto-opening would fire on trash pulls and on other people's
kills.

### Roster health

The section that keeps the ownership model honest. Three lists, each empty in the good case:

1. **Contested characters** — claimed by two or more players (001 §5). Shown prominently in red
   with all claimants named. These characters are enterable by nobody until resolved.
2. **Unclaimed raid members** — present in the raid but in nobody's published roster. Amber.
   Not enterable in v1; the fix is for their owner to claim them (ROADMAP: RL session-claiming).
3. **Addon status** — every raid member with their addon version, or "not running". Version
   drift is visible here before it matters (002 §11).

A **Request rosters** button broadcasts `RREQ` to force a refresh, for when someone has just
fixed their claims.

### Priority list

The Suicide Kings list, always present: it is the section that seeds the list in the first place,
so it cannot be gated on the mode that seeding enables. Full specification in 010 §10 — the
ordered list with owners and absence marked, **Seed**, **Reseed**, **manual reorder**, **manual
suicide / restore**, and the version with its `verify` button.

Every manual action is confirmed, announced to raid chat, version-bumped and written to history.
A silent edit to a public priority list would end the group's trust in it immediately, and unlike
a mis-set tier count it leaves no trace to find afterwards.

### Live batch

Visible while a batch is open:

- Countdown and `4/6 submitted`, with the outstanding names listed rather than just counted.
- Per-item entry counts, so the host can see at a glance that item 4 has nothing on it.
- **Close now** — resolve immediately with whatever has been submitted. The expected path once
  everyone is in.
- **Extend** — adds 60 seconds, announced.
- **Abort** — cancels with reason `MANUAL`. Confirmed, because it discards submitted entries.

### Loot-still-on-corpse banner

Persistent while any corpse-path batch has unresolved or unawarded items (DESIGN §5, 004 §3).
Lists the items and where they are. It exists because a 3-minute window is long enough to walk
away and forget, and a despawned corpse takes the loot with it.

## 4. Announcements — `Modules/Announce.lua`

Only the host announces. Clients never write to raid chat; five copies of every line is how
RaidRoll became something people muted.

Channel: `RAID`, falling back to `PARTY`, then `SAY`, matching PlayerbotManager's pattern.

| Verbosity | Emits |
|---|---|
| **Off** | Nothing |
| **Summary** *(default)* | Batch open (item links + timer), each result line, unclaimed items, aborts, tier-count and timer changes |
| **Verbose** | Everything in Summary, plus every roll, plus tie re-rolls |

Formats:

```
[RLS] Rolling: [Item A] [Item B] [Item C] — 3:00
[RLS] Botty [T2, 83] wins [Item A]
[RLS] [Item B] — no entries, master looter's choice
[RLS] Botty and Sneaky tied on 83 — rerolling
[RLS] Tier count is now 2 (T1, T2, Rest)
```

All output goes through one formatter so the prefix and item-link handling are consistent. Chat
messages are subject to the same throttle discipline as addon messages — a verbose batch of six
items with twenty entries is a lot of lines, so they queue and drain rather than firing at once.

## 5. Acceptance criteria

- The panel is unreachable when not master looter, and closes on losing it.
- Tier count and timer sliders are disabled while a batch is open, with a tooltip saying why.
- Changing tier count broadcasts `CFG`, announces to chat, and updates every client's tier
  badges without a reload.
- Two clients claiming one character surfaces it in Contested with both names.
- A raid member with no roster claim appears in Unclaimed.
- A raid member without the addon shows as "not running" in Addon status.
- Start roll is disabled with a specific reason when loot method is not master loot.
- Close now resolves immediately using only submitted entries.
- Verbosity Off produces zero chat output across a full batch.
- Verbose output for a 6-item, 20-entry batch drains without tripping the client's chat throttle.
