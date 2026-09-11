# Spec 011 — Priority list viewer

**Modules:** `UI/PriorityViewer.lua`, one rule moved into `Core/PriorityList.lua`
**Depends on:** 000, 001, 005, 010

## 1. Scope

A read-only window on the Suicide Kings priority list, for **every player** rather than only the
master looter. It renders the list the client already holds: order, ownership, presence, and
where the viewer sits relative to everyone else.

**Out of scope:**

- Editing of any kind — seed, reseed, move, manual suicide, restore, remove. Those are 010 §10's
  and stay master-looter only.
- `verify` (010 §8) — a replay of the host's event log, which a client does not have.
- Export. `/rls sk list` already prints a pasteable list to chat; that is a different job.
- The history of list edits. Those are announced (010 §10) and logged to history (008).

## 2. Why this exists

The data is already everywhere. `SKLIST` is broadcast to the whole raid on every mutation, and
each client stores it into its own `priority` table regardless of role (010 §8). Every raider's
client knows the exact current order.

The gap is presentational. 010 §10 placed "the list itself, ordered" in the host panel, and 006
§2 gates that panel to the current master looter. So the routes open to a plain raider are:

- `/rls sk list` — the whole list, as 25 lines of chat text.
- The roll window's per-row position (010 §11) — but only for **their own** characters, and only
  while a round is open.

Neither answers "where do I sit relative to everyone else", which is the question an SK list
exists to answer. 010 §10 already argues that "a silent edit to a public priority list would end
the group's trust in it immediately". *Public* has to mean readable by the public, not merely
announced at — a ledger only the banker can read is not a ledger.

This is also the cheapest feature available: no new state, no new protocol, no new authority. It
is a second view onto a table that is already replicated and already kept fresh.

## 3. What it shows

A header: `N characters, version V, seed S`, and whether `SK` is the mode currently in force — a
list can exist while a raid runs under `ROLL`, and a viewer that does not say so invites the
reader to assume tonight's loot is going by these positions.

One row per character, in list order:

| Element | Source | Notes |
|---|---|---|
| Position | rank within the tier | **Superseded by 013 §6.** This specified the list index, from a time when the list was drawn flat; once it is grouped into tier bands the rank inside the band is the character's real place in the queue, and the list index answers a question nothing asks. The index is still what a suicide is announced in and what the log is written in. |
| Name | `order` | Class-coloured, as the host panel's is. |
| Owner | `Roster.claims` | `unclaimed` where nobody claims it. |
| Own marker | viewer's name vs owner | `*`, matching 010 §10's host-panel marker. |
| `contested` | `Roster.IsContested` | Two players claiming one character is a fact the raid should see, not only the host. |
| Absent | `Roster.IsPresent` | Greyed at half alpha, as the host panel does. |
| Above median | §4 | Positions above the raid's present-median are visually distinct. |

The median marker is the same idea as 010 §11's on the roll window rows, for the same stated
reason — *am I near the top* is what people want at a glance — and it must use the same rule, or
the two screens will disagree about the same character on the same night.

## 4. The row model is pure

`PriorityList.viewRows(order, ctx)` in `Core/PriorityList.lua`, with

```lua
ctx = { owners = { [char] = owner }, present = { [char] = true },
        classes = { [char] = "WARRIOR" }, contested = { [char] = true }, me = "Playername" }
```

returning an array of `{ position, char, owner, class, isSelf, contested, present, aboveMedian }`.

Everything interesting here — the median, the ownership decoration, the self marker — is
arithmetic over plain tables. Putting it in `Core/` makes it fixture-testable and leaves
`UI/PriorityViewer.lua` a renderer with no logic worth testing. The WoW-facing lookups
(`Roster.claims`, `IsPresent`, `ClassOf`) are assembled by the caller and passed in, per 000 §2.

**The median rule moves with it.** `RollWindow.AboveMedian` (005) currently owns it. Two copies
of "above the median of present positions" will drift, and the drift is invisible until two
players compare screens. `PriorityList.aboveMedian(position, presentPositions)` becomes the one
definition and `RollWindow.AboveMedian` delegates to it, unchanged in signature so 005's fixtures
keep passing. This is a correction, not a redesign; it is called out because moving a function
out of a spec's module without saying so is what the spec conventions exist to stop.

Absent characters are excluded from the median, matching 010 §6 — they hold their absolute index
and should not drag the midpoint of a list of who is actually here.

## 5. Where it opens from

- **`/rls sk`** (bare) opens the window. `/rls sk list` keeps printing to chat: browsing and
  pasting into Discord are different jobs, and the text form is the better one for pasting.
- **A `Full list` button in the roll window's entry panel**, shown only under `SK` — *added to
  005 §3*. This is the discoverability path. The moment a player wants the whole list is the
  moment they are looking at their own position in the grid and wondering who is above them.
- **No minimap change.** Left-click, shift-click and right-click are all taken (005 §6), and a
  fourth chord on one button is worse than a button in the window already open. This still holds:
  ctrl-click was later spent on the host panel's displaced roll window (006 §3), which had no
  other way in at all, and the viewer still reaches its audience from the window they are already
  looking at.

## 6. Behaviour

- **Everyone, host included.** The host has the editable section, but gating the read-only one
  would leave them unable to see what the raid sees. It is the same window for everybody.
- **Live.** Refreshes off `Priority.RegisterListener`, so a suicide applied mid-round reorders an
  open viewer rather than going stale behind the reader's back.
- **Not seeded** — the window opens and says the list is not seeded, rather than refusing to
  open. "Nothing happened when I typed the command" is indistinguishable from a broken addon.
- **Scrolls.** Forty characters is a normal list. Rows stop a `Widgets.SCROLLBAR_GUTTER` short of
  the scroll frame's right edge.
- Position remembered under `settings.windows.sklist` (000 §4); Escape closes it, via
  `Widgets.Window`.

## 7. What it deliberately does not do

- **No disabled edit controls.** Greyed-out Move buttons on a raider's screen invite "why can't
  I" and imply the permission exists somewhere. The read-only view has no controls at all.
- **No jump-to-me.** The own-character marker plus the median colour is enough; a scroll-to
  control solves a problem a 40-row list does not have.
- **No copy box.** `/rls sk list` is the export.

## 8. Acceptance criteria

**Fixture (`priority` suite)**

- `viewRows` returns rows in list order, positions `1..n`, for a 25-character list.
- A character absent from `ctx.present` is excluded from the median: a list of 10 where 6 are
  absent takes its median over the 4 present positions.
- `aboveMedian` is true from the top of the list through the median position and false below it,
  on both odd and even present-counts.
- A character whose owner is the viewer is marked `isSelf`; one with no claim reports
  `owner = nil` and renders as `unclaimed`.
- An empty `order` returns an empty array rather than erroring.
- `PriorityList.aboveMedian` and `RollWindow.AboveMedian` return the same answer for the same
  input, and every existing 005 fixture passes unchanged.

**`/rls simulate`**

- With a seeded list and an SK round, the viewer lists the same order, version and seed the host
  panel's section shows.
- A suicide applied during an open round reorders an already-open viewer without reopening it.
- With the list seeded but the round running under `ROLL`, the header says `SK` is not in force.
