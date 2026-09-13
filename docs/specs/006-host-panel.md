# Spec 006 — Host panel

**Modules:** `UI/HostPanel.lua`, `Modules/Announce.lua`
**Depends on:** 000, 001, 002, 004
**Player-facing description:** DESIGN §6

---

## 1. Scope

The master looter's control surface: raid settings, round candidates, roster health, live
submission tracking, and the controls that open, close and abort a round.

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
| Tier count | Slider | 3 | 0–5 | Between rounds only |
| Entry timer | Slider | 180s | 15–300s | Between rounds only |
| Quality threshold | Dropdown | Epic | Rare / Epic | Any time |
| Chat verbosity | Dropdown | Summary | Off / Summary / Verbose | Any time |
| Auto-close when all in | Checkbox | Off | — | Any time |
| **Loot mode** | Dropdown | Roll | Roll / Suicide Kings | Between rounds only |

Changing tier count, timer or loot mode broadcasts `CFG` and **announces to raid chat** — these
change the rules everyone is playing by, so they are never silent. All three controls are
disabled with an explanatory tooltip while a round is open (002 §4).

A tier count of 0 shows an inline explanation: *"Flat roll — no priorities."* Under Suicide
Kings, extend it: *"No tiers — the priority list decides every item."*

**Suicide Kings is not selectable until the list is seeded** (010 §5). The dropdown entry is
disabled with the prompt *"Seed the priority list to enable Suicide Kings"*, linking to the
section below. This is why there is no half-configured state to explain: an empty list under SK
is unreachable rather than special-cased.

### Round candidates

Populated on `LOOT_OPENED` (004 §2). Lists each candidate item with icon, link, quality, and a
`x2` badge for duplicates. Each has a checkbox, default ticked.

- **Add item** — accepts a dropped item link or a bag item, for anything the filter excluded.
- **Remove** — takes one item out of the list, whatever put it there: an item-link addition, a
  promoted skipped row, or a plain corpse row. Unticking excludes an item from the next round
  but leaves the row; removing is for a row that should not be on offer at all. It stays out
  until the next corpse scan or an **Add item** on the same link.
- **Start roll** — opens the round with the ticked items. Disabled with a reason when
  preconditions fail (not master loot, no items, round already open).

**After a round closes** its items are withdrawn from the list — they have been rolled for, and
leaving them there invites a second round on loot already awarded. Anything the host left
unticked stays, so the section reads as what is still outstanding. An **abort** withdraws
nothing: the round did not happen, and the host will want to start it again.

Nothing opens automatically. Auto-opening would fire on trash pulls and on other people's
kills.

### Roster health

The section that keeps the ownership model honest. Three lists, each empty in the good case:

1. **Contested characters** — claimed by two or more players (001 §5). Shown prominently in red
   with all claimants named. These characters are enterable by nobody until resolved.
2. **Unclaimed raid members** — present in the raid but in nobody's published roster. Amber.
   Not enterable in v1; the fix is for their owner to claim them (ROADMAP: RL temporary claiming).
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

### Live round

Visible while a round is open:

- Countdown and `4/6 submitted`, with the outstanding names listed rather than just counted.
- Per-item entry counts, so the host can see at a glance that item 4 has nothing on it.
- **Close now** — resolve immediately with whatever has been submitted. The expected path once
  everyone is in.
- **Extend** — adds 60 seconds, announced.
- **Abort** — cancels with reason `MANUAL`. Confirmed, because it discards submitted entries.

### Loot-still-on-corpse banner

Persistent while any corpse-path round has unresolved or unawarded items (DESIGN §5, 004 §3).
Lists the items and where they are. It exists because a 3-minute window is long enough to walk
away and forget, and a despawned corpse takes the loot with it.

### Opening it

`/rls host`, and the **minimap button's left-click while you are master looter**.

The panel had only the slash command for a long time, which is no way in at all for anyone who
has not read `/rls help`. The button gives you the window your role wants rather than one fixed
window: master looter opens the host panel, everyone else opens the roll window during a round
and their hierarchy outside one.

A bare **`/rls`** makes the same decision from the same function. The button and a bare `/rls`
have always opened the same window, and two copies of the rule would drift the first time one of
them changed.

A host does not lose the roll window. It opens itself on `OPEN` and again on the results (005 §2),
and **ctrl-click** reaches it whenever it has something to show. Shift-click is still the
hierarchy and right-click is still a republish. The tooltip names the action the next click will
actually perform, because the primary one now depends on who you are.

## 4. Announcements — `Modules/Announce.lua`

Only the host announces. Clients never write to raid chat; five copies of every line is how
RaidRoll became something people muted.

Channel: `RAID`, falling back to `PARTY`, then `SAY`, matching PlayerbotManager's pattern.

| Verbosity | Emits |
|---|---|
| **Off** | Nothing |
| **Summary** *(default)* | Round open (item links + timer), each result line, unclaimed items, aborts, tier-count and timer changes |
| **Verbose** | Everything in Summary, plus every roll, plus tie re-rolls |

Formats:

```
[RLS] Rolling: [Item A] [Item B] [Item C] — 3:00
[RLS] SK: [Item A] [Item B] [Item C] — 3:00
[RLS] Botty [T2, 83] wins [Item A]
[RLS] [Item B] — no entries, master looter's choice
[RLS] Botty and Sneaky tied on 83 — rerolling
[RLS] Tier count is now 2 (T1, T2, Rest)
```

**The open line leads with the loot mode**, not the word "Rolling" under both. The mode is the
rule the raid is about to play by, the host reads their own announcement, and a mode that is only
visible in a dropdown on one screen is a mode nobody checks. One helper names it, shared with the
`Loot mode is now ...` line, so the two cannot disagree (spec 010 §2).

Chat abbreviates it to `SK`, which is what the group calls it, and what fits beside a row of item
links inside 255 bytes. The host panel, the create dialog and the seed confirmation still spell
out "Suicide Kings": those have room, and they are where someone meets the term for the first
time.

All output goes through one formatter so the prefix and item-link handling are consistent. Chat
messages are subject to the same throttle discipline as addon messages — a verbose round of six
items with twenty entries is a lot of lines, so they queue and drain rather than firing at once.

## 5. Acceptance criteria

- The panel is unreachable when not master looter, and closes on losing it.
- Tier count and timer sliders are disabled while a round is open, with a tooltip saying why.
- Changing tier count broadcasts `CFG`, announces to chat, and updates every client's tier
  badges without a reload.
- Two clients claiming one character surfaces it in Contested with both names.
- A raid member with no roster claim appears in Unclaimed.
- A raid member without the addon shows as "not running" in Addon status.
- Start roll is disabled with a specific reason when loot method is not master loot.
- Close now resolves immediately using only submitted entries.
- Verbosity Off produces zero chat output across a full round.
- Verbose output for a 6-item, 20-entry round drains without tripping the client's chat throttle.
