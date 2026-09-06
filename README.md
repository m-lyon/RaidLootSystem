# Raid Loot System

A loot distribution addon for **World of Warcraft 3.3.5a** (WotLK), built for raids where each
player controls several bot characters alongside their own.

Every player declares the characters they own and puts them in priority order. When a boss dies,
the whole drop table goes up for roll at once — you tick which of your characters want what, and
the highest roll in the highest priority tier wins. The master looter hands the item over with
one click, and the winning bot is told to equip it.

> **Status: design complete, implementation not started.**
> Read [`docs/DESIGN.md`](docs/DESIGN.md) — that's the document to review and argue with.

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

## Documentation

| Document | Audience |
|---|---|
| [`docs/DESIGN.md`](docs/DESIGN.md) | Players. What it does and why. Start here. |
| [`docs/proposals/`](docs/proposals/) | Players. Open questions the group needs to decide |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | What was deliberately left out, and why |
| [`docs/specs/`](docs/specs/) | Implementers. Numbered, self-contained feature specs |

> **Open for review:** [proposal 001 — making loot distribution fairer over
> time](docs/proposals/001-loot-fairness.md). Two options for giving the rules a memory of what
> you've recently received, so a run of bad luck doesn't compound. Neither is switched on until
> the group picks one.

## Contributing

Feature branches, PRs into `main`. Commit subjects reference the spec being implemented:
`spec 003: tie re-roll loop`. Start with [`docs/specs/000-architecture.md`](docs/specs/000-architecture.md)
— it defines the module layout, the pure-core boundary and the comms protocol that everything
else assumes.

## Licence

MIT. See [LICENSE](LICENSE).
