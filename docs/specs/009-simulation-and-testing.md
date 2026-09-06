# Spec 009 — Simulation and testing

**Modules:** `tests/run.lua`, `tests/fixtures/`, `Modules/Simulate.lua`
**Depends on:** 000 (the pure-core boundary is what makes any of this possible)

---

## 1. Why this spec exists

WoW addons have no test harness, and this addon's core is an algorithm whose bugs cost people
items. Without the two mechanisms below, every logic change needs a live 25-man raid to
validate, which means in practice it gets validated by shipping it.

Two independent mechanisms:

1. **Fixture tests** — the pure core, run under a standalone Lua interpreter, in CI.
2. **`/rls simulate`** — the whole pipeline, run solo inside the game.

Neither replaces the other. The first proves the algorithm; the second proves the wiring.

## 2. Fixture tests

### Runner

`tests/run.lua`, executable by `lua5.1` or `luajit`:

```
lua tests/run.lua              # all suites
lua tests/run.lua resolve      # one suite
```

`Core/` files use the addon vararg idiom, which the runner emulates:

```lua
local ns = {}
local function loadCore(path)
    local chunk = assert(loadfile(path))
    return chunk("RaidLootSystem", ns)
end
```

No mocking framework, no dependencies. If a `Core/` file needs a mock to load, it has violated
the purity rule.

### Suites

| Suite | Covers | Source of cases |
|---|---|---|
| `tiers` | Position + tier count → tier, for positions 1–10 × counts 0–5 | 001 §3, 003 |
| `eligibility` | The check order and every reason code, incl. cloaks and tokens | 003 §8 |
| `resolve` | Tier walking, multi-copy spill, boundary ties, unclaimed, degraded | 003 §9 |
| `serialize` | Round-trip of every op, chunk split/join, malformed input rejection | 000 §5 |

### Scripted randomness

`Core/Resolve.lua` takes `rng` as a parameter (000 §7), so tests supply a sequence:

```lua
local function scripted(values)
    local i = 0
    return function(lo, hi) i = i + 1; return values[i] end
end
```

Every case in the `resolve` suite asserts an **exact** outcome. Nothing is asserted
probabilistically — a test that passes 95% of the time is worse than no test, because it trains
people to re-run failures.

### Fixture format

Plain Lua tables in `tests/fixtures/`, one file per suite, each case a table of
`{ name, input, expected }`. Adding a regression case must mean adding a table entry, never
writing new test code — otherwise it stops happening.

## 3. Purity enforcement

CI greps `Core/` for a denylist of WoW globals and fails the build on any hit:

```
CreateFrame, UnitName, UnitClass, GetItemInfo, SendAddonMessage, SendChatMessage,
GetRaidRosterInfo, GetNumRaidMembers, GetLootSlotLink, GetLootMethod,
GiveMasterLoot, GetMasterLootCandidate, GetTime, time, date, math.random,
_G, GameTooltip, print
```

`time` and `math.random` are on the list deliberately: both are the ambient-state dependencies
most likely to sneak into the core and silently destroy reproducibility. Timestamps and
randomness are **passed in**.

A second grep enforces 004 §4's locale rule: no hardcoded English item-class or subclass strings
(`"Plate"`, `"Two-Handed Swords"`, …) anywhere in the codebase.

## 4. `/rls simulate`

An in-game harness that runs the full pipeline solo — no raid, no bots, no other clients.

```
/rls simulate                       # 3 fake players, 4 chars each, 4 items
/rls simulate items=6 players=5     # parameterised
/rls simulate scenario=<name>       # a named scenario from Modules/Simulate.lua
```

**How it works:** `Modules/Simulate.lua` installs a **loopback transport** in place of
`Comms.lua`'s `SendAddonMessage`. Messages are routed to in-process fake clients, each with its
own roster and a scripted submission behaviour. Host and client code paths both execute for real
— only the wire is faked.

It must exercise, end to end: batch open → fake submissions → live `STATE` updates in the roll
window → revision → close → resolution → results rendering → history write.

**Named scenarios**, each reproducing a case that is otherwise hard to stage:

| Scenario | Reproduces |
|---|---|
| `tie` | Boundary tie forcing a visible re-roll |
| `duplicate` | Two copies spilling from T1 into T2 |
| `unclaimed` | An item nobody enters |
| `contested` | Two players claiming the same character |
| `token` | A tier token and its class filtering |
| `special` | An unclassifiable item with the filter off |
| `abort` | Master looter changing mid-batch |
| `chunked` | A payload large enough to require multi-chunk transport |

**Guard rails:**

- Simulation refuses to run while a real batch is open.
- It never sends a real addon message, a real chat message, or a real whisper.
- History records written in simulation are tagged `simulated = true` and excluded from the
  history browser by default.
- The award step is stubbed — `GiveMasterLoot` is never called.

## 5. Manual test checklist

Kept in the repo and run before tagging a release, because some things only exist live:

- Two real clients, one as master looter: open, submit, revise, close, award.
- Award to a bot at range, and out of range.
- Master looter handed over mid-batch → both clients abort with `ML_CHANGED`.
- `/reload` mid-batch on the client → recovers via `SYNC`.
- `/reload` mid-batch on the **host** → clients time out and abort cleanly.
- A real tier token drop → correct classes enterable.
- Auto-equip whisper reaches a bot and is accepted by the server's playerbot build.
- Trade path: take an item, log out, log in, deliver, confirm the pending record closed.

## 6. CI

A GitHub Actions workflow on push and PR:

1. Install `lua5.1`.
2. `lua tests/run.lua` — all suites must pass.
3. Purity grep over `Core/`.
4. Locale grep over the whole addon.
5. `luacheck` if available, warnings non-fatal.

## 7. Acceptance criteria

- `lua tests/run.lua` passes from a clean checkout with no dependencies beyond a Lua 5.1
  interpreter.
- Every acceptance criterion listed in spec 003 exists as a named fixture case.
- Introducing `GetTime()` into any `Core/` file fails CI.
- Introducing the string `"Plate"` as an item-class comparison fails CI.
- `/rls simulate scenario=tie` produces a visible re-roll in the roll window without a raid.
- `/rls simulate` writes no addon messages and no chat output.
- A simulated batch does not appear in the default history browser view.
