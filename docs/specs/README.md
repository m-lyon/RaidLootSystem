# Implementation specs

Numbered, self-contained specs. Each states its scope, its dependencies, its design decisions
and its acceptance criteria.

**Read [`000-architecture.md`](000-architecture.md) first.** Every other spec assumes its module
layout, pure-core boundary, saved-variable schema and comms protocol.

| # | Spec | Modules | Depends on | Status |
|---|---|---|---|---|
| [000](000-architecture.md) | Architecture | *(all)* | — | — |
| [001](001-roster-and-hierarchy.md) | Roster and hierarchy | `Roster`, `Core/Tiers`, `UI/HierarchyEditor` | 000 | **Built** |
| [002](002-session-protocol.md) | Session protocol | `Session`, `Client`, `Comms` | 000, 001 | **Built** |
| [003](003-resolution-engine.md) | Resolution engine | `Core/Resolve`, `Core/Eligibility` | 000, 001 | **Built** |
| [004](004-loot-detection-and-batching.md) | Loot detection and item classification | `LootDetect`, `ItemInfo`, `Data/*` | 000 | **Built** |
| [005](005-roll-window.md) | Roll window | `UI/RollWindow` | 000–004 | **Built** |
| [006](006-host-panel.md) | Host panel | `UI/HostPanel`, `Announce` | 000, 001, 002, 004 | **Built** — the priority-list section is 010's |
| [007](007-award-and-delivery.md) | Award and delivery | `Award`, `Pending` | 000, 002, 003, 004 | Not started |
| [008](008-history-and-export.md) | History and export | `History`, `UI/HistoryBrowser` | 000, 002, 003, 007 | Not started |
| [009](009-simulation-and-testing.md) | Simulation and testing | `tests/`, `Simulate` | 000 | Partial — `tests/run.lua` and the fixture suites; `Simulate` not started |
| [010](010-priority-list.md) | Priority list (Suicide Kings) | `Core/PriorityList`, `Modules/PriorityList`, `Core/Resolve` | 000, 001, 002, 003, 007, 008 | Partial — `Core/Resolve`'s SK path only |

Status is the state of the tree, not of the spec. A spec is written before it is built; a
**Built** row means the module exists, is loaded by the `.toc` and has fixture coverage.

## Suggested build order

**003 and 001 first** — the pure core and the tier model, with fixture tests, before anything
touches a frame. They have no WoW dependencies and everything else rests on them.

Then **000's transport + 002** (the protocol), **004** (getting real items in), **005/006** (the
windows), **007** (delivery), and **008** last.

**009 is not last.** Stand `tests/run.lua` up alongside 003 — it exists to make 003 verifiable,
and retrofitting a test runner after the fact reliably doesn't happen.

**010 can come early — its pure half, at least.** `Core/PriorityList` has no dependencies beyond
Lua and belongs alongside 001 and 003 with its fixtures. The stateful half (storage, sync,
`SKLIST`, restore-on-failure) needs 002 and 007 and should follow them.

**Log 008's `itemLevel` / `quality` / `equipLoc` fields when you build 008**, not later. Nothing
in v1 reads them; they exist so the ROADMAP's ledger-based adjustment stays buildable, and they
cannot be backfilled — `GetItemInfo` needs a warm cache that a months-old history won't have.

## Proposals

[`../proposals/`](../proposals/) holds design questions the group needs to decide — options with
trade-offs, written for players rather than implementers. Spec 010 implements the option chosen
in [proposal 001](../proposals/001-loot-fairness.md); the options that lost are on the roadmap
with their reasoning, not in a spec.

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
