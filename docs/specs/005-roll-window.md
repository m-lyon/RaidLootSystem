# Spec 005 — Roll window

**Modules:** `UI/RollWindow.lua`, `UI/Widgets.lua`
**Depends on:** 000, 001, 002, 003, 004
**Player-facing description:** DESIGN §3

---

## 1. Scope

The window every player uses to enter a round and to read its result. This is the screen that
gets used hundreds of times; it is the addon's centre of gravity.

**Out of scope:** host-only controls (006), awarding (007).

## 2. Two modes, one window

The window has an **entry mode** (round is `OPEN`) and a **results mode** (round is `CLOSED`).
It switches in place rather than opening a second frame, so people's eyes stay in one location.

It opens automatically on `OPEN`, and again on `CLOSED` when the results land. The minimap
button and a bare `/rls` reach it **only while a round is live, or while its results are still on
screen**; once the player closes a concluded round the button goes back to the hierarchy editor.
A concluded round has nothing left to do in it, and leaving it on the button meant every click
for the rest of the night reopened a stale result. Old rounds are read in the history browser
(008), which is what that screen is for.

## 3. Entry mode: the grid

```
┌───────────────────────────────────────────────────────────────┐
│  Lord Marrowgar — 6 items                    2:41   4/6 in    │
├──────────────┬──────┬──────┬──────┬──────┬──────┬──────┬──────┤
│              │ [🗡] │ [🛡] │ [👑] │ [💍] │ [🏹] │ [📿]x2│      │
├──────────────┼──────┼──────┼──────┼──────┼──────┼──────┼──────┤
│ T1  Steve  ● │  ▢   │  ▨   │  ▢   │  ▢   │  ▨   │  ▢   │      │
│ T2  Sneaky ● │  ▣   │  ▨   │  ▢   │  ▢   │  ▨   │  ▢   │      │
│ T3  Smash  ● │  ▨   │  ▢   │  ▣   │  ▢   │  ▨   │  ▢   │      │
│ Rest Locky ○ │  ▨   │  ▨   │  ▨   │  ▨   │  ▨   │  ▨   │      │
├──────────────┴──────┴──────┴──────┴──────┴──────┴──────┴──────┤
│  Selected: [Deathbringer's Will]                              │
│    T1  Bonk (Dave)      T2  Sneaky (Steve)                    │
│    Rest Grubby (Dave)   Rest Stabby (Anna)                    │
├───────────────────────────────────────────────────────────────┤
│  [ Pass all ]                              [ Submit 2 entries ]│
└───────────────────────────────────────────────────────────────┘
```

`▢` enterable · `▣` ticked · `▨` disabled · `●` present · `○` not present

### Rows — your roster

- Ordered by hierarchy position, so your highest priority is at the top.
- **Tier badge** on every row, computed for the round's frozen tier count. Colour-coded, with
  Rest visually distinct from the numbered tiers.
- **Priority position** beside it under `lootMode = "SK"` (010 §11) — the character's rank
  inside its tier, the same number the priority viewer draws (013 §6), with list positions above
  the raid's median visually distinct. *Am I near the top* is the thing people want to know at a
  glance. Nothing renders under `ROLL`. This was the list index until 013 §6 banded the list: a
  tier is walked to exhaustion before the next, so the global index is not a place in any queue,
  and two screens numbering one character differently read as a bug.
- **The star control** under `SK` — one radio per character row across the item columns, marking
  that character's priority pick and clearing any previous star for it.
- Class-coloured name; a marker on your own character.
- Presence dot. Absent characters render greyed with every cell disabled.
- A **"hide ineligible rows"** toggle collapses the grid to only rows with at least one
  enterable cell. Off by default — seeing that your Warrior *can't* use anything here is
  useful information.

### Columns — the round's items

- Item icon with the standard `GameTooltip` on hover, and a click that chat-links the item.
- A `x2` badge for duplicate drops.
- A marker on items flagged `special` (004 §6) with a tooltip: *"Eligibility filter off — check
  yourself."*
- Six columns fit comfortably; beyond that the grid scrolls horizontally with the row header
  frozen.

### Cells

- Left-click toggles the entry.
- Disabled cells carry a tooltip giving the **reason code** from `Core/Eligibility` in plain
  language — `"Warriors can't use cloth"`, `"Not in the raid"`, `"Contested — Steve and Dave
  both claim Sneaky"`.
- **Right-click sets the override flag** on an eligibility-failed cell, enabling it and marking
  it with a distinct border. `NOT_IN_RAID` and `CONTESTED` are not overridable (003 §8) and
  right-click does nothing on them.

### The detail panel

Below the grid, showing the **currently selected column**: every entry the host has accepted
for that item, from the latest `STATE`, grouped by tier and labelled with the owning player.

This is where DESIGN's "fully open" promise actually lands. It updates live as people submit
and revise. It renders **only** from host `STATE` (002 §7) — never from local optimism.

Under `SK` it orders entrants by **list position** rather than grouping them by tier alone, so
the outcome is legible before submission. Suicide Kings is deterministic: once the field is
known the winner is known, and presenting it as suspenseful would be theatre. The panel should
read as *"this is who wins unless someone else enters"*.

Each entrant is numbered by its rank inside its tier, as on the grid rows; the order is still
list position, which orders a tier identically.

The positions come from the host's `SKLIST` (010 §8), never from local state. A client that has
not received it shows positions as unknown and says so — substituting its own copy could show a
player a position the host will not honour.

### Footer

- **Countdown** to `endsAt`, turning amber in the last 30 seconds.
- **Submitted counter** — `4/6 in`, tooltip listing who hasn't submitted.
- **Submit** — sends the whole grid. After first submit the button reads **Revise**, and a
  dirty-state indicator shows when local ticks differ from what the host has accepted.
- **Pass all** — clears every tick and submits an empty set, which is materially different from
  never submitting: it marks you as in, so the host can force-close.

## 4. Submission feedback

After `SUBMIT`, compare the accepted-entry count in the next `STATE` against what was sent
(002 §5). On a mismatch, show a visible warning naming the dropped entries and why. Silently
losing an entry and discovering it after the roll is the failure mode that destroys trust in a
loot addon, so it gets a loud, specific message rather than a generic error.

## 5. Results mode

On `RESULT` + `ROLLS`, the window switches. Per item:

- **Winner banner** — class-coloured character name, owning player, tier, winning roll. For
  duplicate drops, both winners in copy order.
- **Full roll table** — every entry: character, owner, tier, and either the roll (`ROLL`) or the
  list position (`SK`). Sorted by tier, then roll descending or position ascending. The numbers
  come from `ROLLS`, never from a local re-derivation. `ROLLS` therefore carries a per-entry
  status (rolled / not consulted / withdrawn) and the re-roll list (000 §5); the roll value alone
  cannot distinguish a not-consulted entry from a withdrawn one, and a client that guessed would
  mislabel someone's entry.
- Under `SK` the number drawn is each consulted entry's **rank inside its tier among that item's
  entrants** — the order the tier was walked in. Not the list-wide rank the entry grid shows: by
  results the list has moved, and `ROLLS` carries list indices only for who entered, so that
  number cannot be rebuilt here or from a history record, which renders through this same view.
  Ranking `ROLLS`' own indices is an ordering of the host's numbers, not a re-derivation of the
  outcome. Not-consulted and withdrawn entries take no rank.
- Under `SK`, the winner's row also shows `-> suicide` after its tier rank. Not `-> bottom`: a
  suicide lands on the last present index, which need not be the last row (010 §6), and the list
  index that would qualify "bottom" is not shown to players -- it is the number the list is keyed
  and logged by, not a place in anyone's queue. Entries removed by the one-win rule or
  by another character's star are marked `withdrawn (won [Item])` (010 §7). An entry that
  silently vanished from the results table is indistinguishable from a bug.
- **Not-consulted entries shown explicitly**, greyed, labelled `"T3 — not consulted"` (003 §5).
  Showing them is what makes the tier rule legible: people can see their entry was never rolled
  *because* a higher tier was occupied, rather than assuming they lost a roll.
- **Re-rolls shown inline** — `"83 → 47 (tie re-roll)"`.
- `unclaimed` items get an explicit "No entries — master looter's choice" state.
- A `degraded` result (003 §6) shows a warning badge.

For the host only, each item's row carries its **award control** (007). Nobody else sees it.

Results stay readable until the next round opens, and older ones are reachable from the history
browser (008).

## 6. Behaviour details

- **Never steals focus or key input.** People are still fighting; the window must not eat
  keybinds.
- Draggable, position saved per character in `settings.windows`, closable with Escape.
- If closed during an open round, the minimap button pulses until submitted.
- On `ABORT`, the window shows the reason in place for 10 seconds before closing itself.
- A `/reload` mid-round restores state via `SYNC` (002 §10), including local ticks that were
  never submitted, which are held in a scratch table that survives the reload.

## 7. Acceptance criteria

- A round of 6 items with a 9-character roster renders without scrolling at default UI scale.
- A plate item disables every cloth/leather/mail row, with a class-specific tooltip reason.
- Right-clicking a `WRONG_ARMOR` cell enables it with a visible override marker; right-clicking
  a `NOT_IN_RAID` cell does nothing.
- Another player submitting causes the detail panel to update within one `STATE` coalescing
  window (≤ 0.5s) without any local action.
- Submitting, then re-ticking, shows the dirty indicator; re-submitting clears it.
- Pass all marks the player as submitted with zero entries.
- Results mode shows not-consulted entries as such, not as losses.
- Closing and reopening the window mid-round preserves unsubmitted ticks.
- `/reload` mid-round restores the grid, the countdown, and unsubmitted ticks.
