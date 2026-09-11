# Raid Loot System

A loot distribution addon for **World of Warcraft 3.3.5a** (WotLK), built for raids where each
player controls several bot characters alongside their own.

Every player declares the characters they own and puts them in priority order. When a boss dies,
the whole drop table goes up for roll at once — you tick which of your characters want what, and
the highest roll in the highest priority tier wins. The master looter hands the item over with
one click, and the winning bot is told to equip it.

> **Status: 0.x, implemented, not yet survived a real raid night.**
> Read [`docs/DESIGN.md`](docs/DESIGN.md) for the player-facing intent behind it.
>
> **Campaigns** — separate groups, each with their own priority list — are built. See
> [Campaigns](#campaigns) below and [spec 012](docs/specs/012-campaigns.md) for the design.

---

## Why not RaidRoll?

RaidRoll and its relatives assume one human, one character, one roll. They have no way to say
"these four characters all belong to me, and I care about them in this order", which is the
entire problem when most of the raid is bots that can't advocate for themselves.

## Requirements

- WoW client 3.3.5a (interface 30300)
- AzerothCore with **mod-playerbots**
- Master Loot enabled for the automated award path
- Every human raider running the addon, on the same version

## Installation

Clone or extract into your AddOns folder so the path looks like:

```
World of Warcraft/Interface/AddOns/RaidLootSystem/RaidLootSystem.toc
```

Then `/reload` or restart the client.

## Quick start

1. **`/rls`** opens the hierarchy editor. Add your own character and each bot you control, then
   drag them into priority order — the character you most want geared goes at the top.
2. The **raid leader** sets how many priority tiers count for the raid (default 3) from the host
   panel. Everything below the cut-off shares an equal-chance "Rest" tier.
3. **Kill a boss.** The master looter opens the corpse and starts the roll.
4. **Tick what you want.** One grid, all of the boss's drops, all of your characters. Cells grey
   out where a character can't use the item. Submit once.
5. **The result is public** — every entry, every tier, every roll. The master looter clicks once
   to hand the item over.

Everything above, and quite a bit more, is also reachable from chat — see [Chat
commands](#chat-commands) below, or just type `/rls help` in game.

## Chat commands

Everything runs through one slash command: **`/rls`** (`/raidloot` also works, if `/rls` is
ever taken by something else). This section groups every subcommand by what you're trying to do.
For *why* the addon works this way, see [`docs/DESIGN.md`](docs/DESIGN.md) — the section
references below point there.

Typing `/rls` with nothing after it does the useful thing for the moment: it opens the **roll
window** if a round is open, or your **hierarchy** if nothing is happening right now. `/rls
help` (or any command it doesn't recognise) prints the same list you see here, in-game.

### Every player

These work for anyone running the addon, whether or not you're the master looter.

| Command | What it does |
|---|---|
| `/rls` | Roll window if a round is open, otherwise your hierarchy. |
| `/rls window` | Open the roll window directly. |
| `/rls hierarchy` | Open your hierarchy — add characters and drag them into priority order. See [DESIGN §2](docs/DESIGN.md#2-core-concepts). |
| `/rls history` | Open the history browser — every past round: what dropped, who entered, who won. See [DESIGN §8](docs/DESIGN.md#8-history). |
| `/rls status` | Print your addon version, roster size, who's hosting, and any roster conflicts. |
| `/rls publish` | Resend your roster to the raid, in case someone's copy is stale. |
| `/rls request` | Ask everyone in the raid to resend their roster. |
| `/rls sync` | Ask the master looter to resend the currently open round, if your window looks stuck or empty. Rate-limited — you'll be told to wait if you just asked. |
| `/rls itemclasses` | Print your client's item-class ordering. Only useful when helping verify [`Data/ItemClasses.lua`](Data/ItemClasses.lua) against a live client. |
| `/rls debug` | Toggle extra diagnostic chat messages for this session. Off by default; not needed for normal play. |

### During a roll

Once the master looter opens a round, one grid covers every item on the corpse. Tick which of
your characters want which item and submit — see [DESIGN
§3](docs/DESIGN.md#3-a-raid-night-end-to-end) for the full walkthrough.

| Command | What it does |
|---|---|
| `/rls window` | Bring the roll window back if you closed it while a round is still open. |
| `/rls sync` | Ask the host to resend the round if your window is out of sync. |

### Suicide Kings

Only relevant once your raid leader has turned on Suicide Kings mode (see [DESIGN
§9](docs/DESIGN.md#9-suicide-kings)). The list is one ordered queue of every character in every
roster; winning an item sends that character to the bottom.

| Command | What it does |
|---|---|
| `/rls sk` | Open the read-only priority list viewer — see where every character stands. Anyone can open this at any time. |
| `/rls sk list` | Print the priority list to chat instead of opening a window. |
| `/rls sk verify` | Replay the list from its original seed and report any drift. Doesn't fix anything — it's a check, not a repair. See [DESIGN §9](docs/DESIGN.md#9-suicide-kings) and [spec 010 §8](docs/specs/010-priority-list.md). |

Seeding the list, reordering it, or correcting an entry by hand are raid-leader actions done from
the host panel (`/rls host`), not from chat — every such change is announced in raid chat and
recorded.

### Pending deliveries

Normally loot goes straight to the winner off the corpse. If the master looter has to loot an
item themselves instead (the winner's out of range, the corpse is about to despawn), it becomes a
**pending delivery** with a 2-hour trade window — see [DESIGN
§5](docs/DESIGN.md#5-getting-the-item-to-the-winner).

| Command | What it does |
|---|---|
| `/rls pending` | List items you're currently holding for someone else, with their numbers. |
| `/rls deliver <n>` | Open a trade with the winner of pending item `<n>`. |
| `/rls abandon <n>` | Give up on delivering pending item `<n>`. Asks for confirmation first — this can't be undone. |

### Running the raid (master looter / raid leader)

These drive the loot pipeline. Most require you to actually be the current master looter —
you'll get an error message back if you're not.

| Command | What it does |
|---|---|
| `/rls host` | Open the host panel: raid-wide settings, Suicide Kings list management, round controls. |
| `/rls loot` | List what's on the open corpse that's worth rolling for, and why anything was skipped (below the quality bar, no addon data, etc). |
| `/rls start` | Open a round covering everything `/rls loot` found. |
| `/rls roll <link>` | Open a round for one specific item — for something `/rls loot` didn't pick up, or a non-corpse award. Example: `/rls roll [Shadowmourne]`. |
| `/rls close` | Resolve the open round right now, instead of waiting for the entry timer. |
| `/rls cancel` | Cancel the open round outright — nothing is awarded. |
| `/rls tiers <0-5>` | Set how many priority tiers count for the raid; everything below shares an equal-chance "Rest" tier. Takes effect on the next round, not the current one. See [DESIGN §2](docs/DESIGN.md#2-core-concepts). |
| `/rls quality <3\|4>` | Set the quality bar the corpse scan applies — `3` for rare and up, `4` for epic only. |

### Trying it out solo

You don't need a raid, or even a group, to see the pipeline work.

| Command | What it does |
|---|---|
| `/rls simulate` | Run a full loot round against fake items and fake raiders, right now, solo. |
| `/rls simulate items=N players=N scenario=name` | Same, with the round size, roster size, or scenario controlled. `/rls simulate list` prints the available scenario names. |
| `/rls simulate stop` | End a running simulation and restore your real roster and settings. |

See [spec 009](docs/specs/009-simulation-and-testing.md) for what a simulation does and doesn't
touch.

### Troubleshooting

- **Nothing happens when you type `/rls`.** Check the addon actually loaded: `/rls status`
  should print a version number. If it doesn't, confirm the folder is
  `Interface/AddOns/RaidLootSystem/RaidLootSystem.toc` and `/reload`.
- **Your roll window looks empty or stale during a live round.** `/rls sync` asks the host to
  resend it.
- **A character can't be entered on your own roster.** `/rls status` lists contested characters
  (claimed by more than one player) and group members nobody has claimed yet.
- **Something in the priority list looks wrong.** `/rls sk verify` checks it against its seed
  and tells you if it's drifted; ask your raid leader to correct it from the host panel.

## Campaigns

> [Spec 012](docs/specs/012-campaigns.md) is the full design; [DESIGN §2](docs/DESIGN.md#2-core-concepts)
> is the player-facing version. A fresh install has no campaign — make one with
> `/rls campaign new <label>`, or wait for your raid leader to invite you into theirs.

A **campaign** is a named group you raid with. It owns the priority list, the raid leader's
settings, and each person's ordering — and none of that is visible to any other campaign.

Most groups need exactly one and never think about it again. You want a second when the people or
the characters change in a way that shouldn't share a priority list:

| Situation | Why a separate campaign |
|---|---|
| Sunday alt run | Different characters lead. Your ordering and the list are genuinely different. |
| Guesting in another guild | Their list is theirs. Yours stays untouched. |
| A splinter group with its own rules | Its own tier count, timer and loot mode. |

Two properties worth knowing up front:

- **A campaign never ends.** There is nothing to start or close down at the end of the night.
  You switch between campaigns, and each is exactly where you left it.
- **You only join by invitation.** The master looter presses a button, you get a prompt, and you
  choose whether to join and which of your characters to bring. Nothing joins you automatically —
  which is what stops a guest night with strangers from overwriting the list your own group has
  spent a month building.

Commands:

| Command | What it does |
|---|---|
| `/rls campaign` | List your campaigns, marking the active one. |
| `/rls campaign new <label>` | Create one, then pick which characters you're bringing. |
| `/rls campaign switch <n>` | Change the active campaign. |
| `/rls campaign rename <label>` | Rename the active campaign. |
| `/rls campaign delete <n>` | Delete one, after a confirmation. |
| `/rls campaign invite` | Master looter only — invite the raid to join this campaign. |
| `/rls campaign export` / `import <string>` | Move a whole campaign between clients. |

> **If you ever lose your saved variables,** import a campaign string from somebody else in the
> group rather than creating a new campaign. Same id, same list, continuity intact. Creating a
> fresh one silently starts a second priority list that looks completely normal.

## Documentation

| Document | Audience |
|---|---|
| [`docs/DESIGN.md`](docs/DESIGN.md) | Players. What it does and why. Start here. |
| [`docs/proposals/`](docs/proposals/) | Players. Questions the group decides, and the reasoning |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | What was deliberately left out, and why |
| [`docs/specs/`](docs/specs/) | Implementers. Numbered, self-contained feature specs |

> **Decided:** [proposal 001](docs/proposals/001-loot-fairness.md) — the group chose **Suicide
> Kings** over two ledger-based alternatives. One ordered list of every character; highest on the
> list wins their tier; the winner drops to the bottom. No rolls, nothing to predict.
> [DESIGN §9](docs/DESIGN.md) explains it; [spec 010](docs/specs/010-priority-list.md) builds it.

## Contributing

Feature branches, PRs into `main`. Commit subjects reference the spec being implemented:
`spec 003: tie re-roll loop`. Start with [`docs/specs/000-architecture.md`](docs/specs/000-architecture.md)
— it defines the module layout, the pure-core boundary and the comms protocol that everything
else assumes.

## Licence

MIT. See [LICENSE](LICENSE).
