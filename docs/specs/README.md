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

## Suggested build order

**003 and 001 first** — the pure core and the tier model, with fixture tests, before anything
touches a frame. They have no WoW dependencies and everything else rests on them.

Then **000's transport + 002** (the protocol), **004** (getting real items in), **005/006** (the
windows), **007** (delivery), and **008** last.

**009 is not last.** Stand `tests/run.lua` up alongside 003 — it exists to make 003 verifiable,
and retrofitting a test runner after the fact reliably doesn't happen.

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
