# Implementation specs

Numbered, self-contained specs. Each states its scope, its dependencies, its design decisions
and its acceptance criteria.

**Read [`000-architecture.md`](000-architecture.md) first.** Every other spec assumes its module
layout, pure-core boundary, saved-variable schema and comms protocol.

| # | Spec | Modules | Depends on |
|---|---|---|---|
| [000](000-architecture.md) | Architecture | *(all)* | — |
| [001](001-roster-and-hierarchy.md) | Roster and hierarchy | `Roster`, `Core/Tiers`, `UI/HierarchyEditor` | 000 |
| [002](002-session-protocol.md) | Session protocol | `Session`, `Client`, `Comms` | 000, 001 |
| [003](003-resolution-engine.md) | Resolution engine | `Core/Resolve`, `Core/Eligibility` | 000, 001 |
| [004](004-loot-detection-and-batching.md) | Loot detection and item classification | `LootDetect`, `ItemInfo`, `Data/*` | 000 |
| [005](005-roll-window.md) | Roll window | `UI/RollWindow` | 000–004 |
| [006](006-host-panel.md) | Host panel | `UI/HostPanel`, `Announce` | 000, 001, 002, 004 |
| [007](007-award-and-delivery.md) | Award and delivery | `Award`, `Pending` | 000, 002, 003, 004 |
| [008](008-history-and-export.md) | History and export | `History`, `UI/HistoryBrowser` | 000, 002, 003, 007 |
| [009](009-simulation-and-testing.md) | Simulation and testing | `tests/`, `Simulate` | 000 |
| [010](010-loot-ledger.md) | Loot ledger | `Core/Ledger`, `Core/GearScore`, `Modules/Ledger` | 000, 003, 004, 007, 008 |
| [011](011-fairness-modes.md) | Fairness modes | `Core/Fairness`, `Core/Resolve` | 003, 010 |

## Suggested build order

**003 and 001 first** — the pure core and the tier model, with fixture tests, before anything
touches a frame. They have no WoW dependencies and everything else rests on them.

Then **000's transport + 002** (the protocol), **004** (getting real items in), **005/006** (the
windows), **007** (delivery), and **008** last.

**009 is not last.** Stand `tests/run.lua` up alongside 003 — it exists to make 003 verifiable,
and retrofitting a test runner after the fact reliably doesn't happen.

**010 and 011 come after 008**, since the ledger is derived from history records and cannot be
built before there are any. But **the history fields 010 needs (`gsValue`, `ledgerAtOpen`) must
land with 008 itself**, not later: they are written under every mode including `OFF`, and a
group that raids for a month before enabling a fairness mode should find a month of usable
ledger waiting rather than starting from zero.

**011 is trivial once 010 exists**, and that is by design — the two modes are a few dozen lines
of pure arithmetic each. If implementing 011 feels large, something that belongs in 010 has
leaked into it.

## Proposals

[`../proposals/`](../proposals/) holds open design questions — options with trade-offs, written
for players rather than implementers. A spec may be written against a proposal that has not been
decided yet (010 and 011 both are); it ships switched off until the group chooses.

## Conventions for spec authors

New features get a new numbered spec rather than edits to an existing one, unless the change is
genuinely a correction. Each spec carries:

- **Scope** and an explicit **out of scope**
- **Depends on**
- The **decisions** it encodes, with the reasoning — a spec that only says *what* leaves the next
  person free to "simplify" away something load-bearing
- **Acceptance criteria** that are demonstrable via fixture test or `/rls simulate`

Deferred ideas go in [`../ROADMAP.md`](../ROADMAP.md) with their deferral rationale, not into a
spec as a "future" section.
