# Review instructions

RaidLootSystem is a World of Warcraft 3.3.5a addon (Lua 5.1) for raid loot
distribution. `CLAUDE.md` and the specs in `docs/specs/` are the rules of the
codebase; check changes against them, and when a spec and the code disagree,
say which one should change. Reviews are fed into an automated fix loop, so
every finding you raise will probably be implemented. Raise only findings that
are worth the code they will add.

## Proportionality comes first

- Only flag defects that this diff introduces or makes worse. Do not audit
  surrounding code the diff did not touch.
- Weigh each finding against the complexity its fix would add. If a fix for an
  unlikely edge case would add more than a few lines, or a new state table,
  flag or wire message, recommend documenting the limitation instead.
- When reviewing a commit that addresses earlier review findings, judge whether
  the fix is proportionate to the problem. Unnecessary complexity added by a fix
  is itself a finding, and simplifying or reverting it is a valid
  recommendation.
- Do not raise a new edge case inside code that exists only to handle another
  edge case, unless it costs someone an item, loses history, or breaks a round.
- Do not repeat a finding that a comment on an earlier review has marked as
  intentional or won't-fix.
- State the invariant a finding violates as the main fix. Offer a concrete patch
  only once you have checked it against the code's lifecycle (when tables are
  released, when rounds close), and mark it as a suggestion.
- A review with no findings is a good outcome. Do not pad it.

## Out of scope

Do not flag:

- Anything `tests/purity.sh` or luacheck already catches.
- Performance at raid sizes. A raid is at most 40 characters, so per-row work is
  fine unless it runs every frame (`OnUpdate`) or grows worse than linearly with
  campaign history.
- Text layout at unusual window sizes, unless it hides a control or a warning.
- A missing fixture for code below a file's "WoW-facing" divider. The pure test
  runner cannot reach it, so the request will be declined. If the logic needs
  coverage, name the pure function to extract above the divider, with its
  signature, as the fix.

## Worth flagging

These repeatedly turned out to be real in past reviews:

- **The host reading its own echo.** `ns.Client.round` only updates when the
  host's own messages loop back through Comms, so it lags by seconds or never
  arrives. A host-only decision (setup, Start roll, auto-close, closing the loot
  frame, releasing a round) must read `ns.Round.current`. Also flag a Client
  notification handler with side effects in a `state == "CLOSED"` or `"OPEN"`
  branch and no guard for the round it already handled. Those handlers fire on
  every `CFG`, `RESULT` and `ROLLS`, including the host's own loopback.
- **One rule written in two places.** Flag a predicate spelled out inline where
  a helper for it already exists, or two copies that disagree on an edge case.
  Award delivery state is the usual culprit: check AWAITING, retryable FAILED,
  non-retryable FAILED, LOST and slotless (trade) records. A `/rls` command and
  the button it mirrors must use the same gate and payload.
- **Fixtures that pass under the bug.** For each new or changed case, ask
  whether it would fail if the rule were inverted. Flag inputs the function
  never reads, cases that differ only in such an input, and case names that
  describe something other than what is asserted.
- **Create without release.** A table that outlives a round must be cleared on
  every exit path (close, abort, encode failure), from the same layer that fills
  it, not left to a UI listener.
- **Wire messages that can grow without bound.** At `C.CHUNK_BODY_MAX`,
  `C.SEND_RATE` and `C.REASSEMBLY_TIMEOUT`, a message over roughly 40 chunks
  (about 7 KB) can never be reassembled, and nothing reports it. A payload that
  grows with campaign length needs a bound. A value computed at encode time
  that must be fresh at send time goes through `Comms.SendDeferred`.
- **Slot numbers are not identity.** Loot slots restart on every corpse, so a
  slot-bound decision must also check that the open corpse is the round's
  corpse.
- **Comments, labels and specs that say something the code doesn't.** This
  includes ignored parameters, fallbacks not taken, warnings promising an action
  another gate refuses, unreachable branches and functions with no caller.
  Also flag a new function inserted between another function and its `---` doc
  block. These are fine to report at Low.
