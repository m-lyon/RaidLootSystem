# Chat commands

Everything runs through one slash command: **`/rls`** (`/raidloot` also works, if `/rls` is
ever taken by something else). This page groups every subcommand by what you're trying to do.
For *why* the addon works this way, see [`DESIGN.md`](DESIGN.md) — the section references below
point there.

Typing `/rls` with nothing after it does the useful thing for the moment: it opens the **roll
window** if a batch is open, or your **hierarchy** if nothing is happening right now. `/rls
help` (or any command it doesn't recognise) prints the same list you see here, in-game.

## Every player

These work for anyone running the addon, whether or not you're the master looter.

| Command | What it does |
|---|---|
| `/rls` | Roll window if a batch is open, otherwise your hierarchy. |
| `/rls window` | Open the roll window directly. |
| `/rls hierarchy` | Open your hierarchy — add characters and drag them into priority order. See [DESIGN §2](DESIGN.md#2-core-concepts). |
| `/rls history` | Open the history browser — every past batch: what dropped, who entered, who won. See [DESIGN §8](DESIGN.md#8-history). |
| `/rls status` | Print your addon version, roster size, who's hosting, and any roster conflicts. |
| `/rls publish` | Resend your roster to the raid, in case someone's copy is stale. |
| `/rls request` | Ask everyone in the raid to resend their roster. |
| `/rls sync` | Ask the master looter to resend the currently open batch, if your window looks stuck or empty. Rate-limited — you'll be told to wait if you just asked. |
| `/rls itemclasses` | Print your client's item-class ordering. Only useful when helping verify [`Data/ItemClasses.lua`](../Data/ItemClasses.lua) against a live client. |
| `/rls debug` | Toggle extra diagnostic chat messages for this session. Off by default; not needed for normal play. |

## During a roll

Once the master looter opens a batch, one grid covers every item on the corpse. Tick which of
your characters want which item and submit — see [DESIGN §3](DESIGN.md#3-a-raid-night-end-to-end)
for the full walkthrough.

| Command | What it does |
|---|---|
| `/rls window` | Bring the roll window back if you closed it while a batch is still open. |
| `/rls sync` | Ask the host to resend the batch if your window is out of sync. |

## Suicide Kings

Only relevant once your raid leader has turned on Suicide Kings mode (see [DESIGN
§9](DESIGN.md#9-suicide-kings)). The list is one ordered queue of every character in every
roster; winning an item sends that character to the bottom.

| Command | What it does |
|---|---|
| `/rls sk` | Open the read-only priority list viewer — see where every character stands. Anyone can open this at any time. |
| `/rls sk list` | Print the priority list to chat instead of opening a window. |
| `/rls sk verify` | Replay the list from its original seed and report any drift. Doesn't fix anything — it's a check, not a repair. See [DESIGN §9](DESIGN.md#9-suicide-kings) and [spec 010 §8](specs/010-priority-list.md). |

Seeding the list, reordering it, or correcting an entry by hand are raid-leader actions done from
the host panel (`/rls host`), not from chat — every such change is announced in raid chat and
recorded.

## Pending deliveries

Normally loot goes straight to the winner off the corpse. If the master looter has to loot an
item themselves instead (the winner's out of range, the corpse is about to despawn), it becomes a
**pending delivery** with a 2-hour trade window — see [DESIGN
§5](DESIGN.md#5-getting-the-item-to-the-winner).

| Command | What it does |
|---|---|
| `/rls pending` | List items you're currently holding for someone else, with their numbers. |
| `/rls deliver <n>` | Open a trade with the winner of pending item `<n>`. |
| `/rls abandon <n>` | Give up on delivering pending item `<n>`. Asks for confirmation first — this can't be undone. |

## Running the raid (master looter / raid leader)

These drive the loot pipeline. Most require you to actually be the current master looter —
you'll get an error message back if you're not.

| Command | What it does |
|---|---|
| `/rls host` | Open the host panel: raid-wide settings, Suicide Kings list management, batch controls. |
| `/rls loot` | List what's on the open corpse that's worth rolling for, and why anything was skipped (below the quality bar, no addon data, etc). |
| `/rls start` | Open a batch covering everything `/rls loot` found. |
| `/rls roll <link>` | Open a batch for one specific item — for something `/rls loot` didn't pick up, or a non-corpse award. Example: `/rls roll [Shadowmourne]`. |
| `/rls close` | Resolve the open batch right now, instead of waiting for the entry timer. |
| `/rls cancel` | Cancel the open batch outright — nothing is awarded. |
| `/rls tiers <0-5>` | Set how many priority tiers count for the raid; everything below shares an equal-chance "Rest" tier. Takes effect on the next batch, not the current one. See [DESIGN §2](DESIGN.md#2-core-concepts). |
| `/rls quality <3\|4>` | Set the quality bar the corpse scan applies — `3` for rare and up, `4` for epic only. |

## Trying it out solo

You don't need a raid, or even a group, to see the pipeline work.

| Command | What it does |
|---|---|
| `/rls simulate` | Run a full loot batch against fake items and fake raiders, right now, solo. |
| `/rls simulate items=N players=N scenario=name` | Same, with the batch size, roster size, or scenario controlled. `/rls simulate list` prints the available scenario names. |
| `/rls simulate stop` | End a running simulation and restore your real roster and settings. |

See [spec 009](specs/009-simulation-and-testing.md) for what a simulation does and doesn't touch.

## Troubleshooting

- **Nothing happens when you type `/rls`.** Check the addon actually loaded: `/rls status`
  should print a version number. If it doesn't, confirm the folder is
  `Interface/AddOns/RaidLootSystem/RaidLootSystem.toc` and `/reload`.
- **Your roll window looks empty or stale during a live batch.** `/rls sync` asks the host to
  resend it.
- **A character can't be entered on your own roster.** `/rls status` lists contested characters
  (claimed by more than one player) and group members nobody has claimed yet.
- **Something in the priority list looks wrong.** `/rls sk verify` checks it against its seed
  and tells you if it's drifted; ask your raid leader to correct it from the host panel.
