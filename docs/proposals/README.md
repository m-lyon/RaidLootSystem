# Proposals

Decisions the group needs to make, written up so they can be argued about before anything is
built. A proposal presents **options**, not a plan — it exists because there is a real choice
with real trade-offs and the answer isn't obvious from the code.

Distinct from the other two document types:

| | Answers |
|---|---|
| [`../DESIGN.md`](../DESIGN.md) | What the addon **does** |
| [`../specs/`](../specs/) | How it is **built** |
| **`proposals/`** | What it **should do**, when that is still open |

A proposal is written for players, not implementers: light on code, heavy on worked examples
and consequences. Once the group decides, the outcome folds into `DESIGN.md`, the losing
options move to [`../ROADMAP.md`](../ROADMAP.md), and the proposal stays where it is as a
record of the reasoning.

| # | Proposal | Status |
|---|---|---|
| [001](001-loot-fairness.md) | Making loot distribution fairer over time | **Decided** — Suicide Kings ([spec 010](../specs/010-priority-list.md)) |

A decided proposal keeps its full comparison rather than being trimmed to the winner. "Why did we
not do the obvious thing?" is the question that gets re-asked, and the losing options are the
only answer to it. If the group later picks an option the proposal did not contain, add it to the
comparison rather than appending a note — a document that argues for two things and concludes
"we chose neither" teaches nobody anything.
