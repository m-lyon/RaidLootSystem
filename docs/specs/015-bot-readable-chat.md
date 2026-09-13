# Spec 015 — Chat a bot can read

**Modules:** additions to `Modules/Announce.lua`, `Modules/Round.lua`, `Core/Constants.lua`,
`UI/HostPanel.lua`, `RaidLootSystem.lua`
**Depends on:** 006, 007

## 1. Scope

One client setting, **on by default**, that stops this client putting item links in party or raid
chat, because on this server chat is not inert.

**Out of scope:**

- Guessing the correct `equip` syntax for a given playerbot build. That is still unconfirmed
  (spec 007 §7) and this spec does not pretend to settle it.
- Any change to how items are resolved, awarded or delivered.
- Suppressing announcements, which `verbosity = OFF` already does.

## 2. The problem

Bots read their master's party and raid chat and act on what they find, and **an item link there
is answered by opening a trade**. Confirmed in game on this server, not a precaution.

This addon links items in two announcements: the open line lists every item on the corpse, and the
win line names the item. So starting a roll or awarding loot made every bot in the group that
could act on the link open a trade with the host.

The `equip <link>` whisper after a delivery (007 §7) was the other suspect and is **not** the
cause. It was tested and cleared: a whisper is a command addressed to one bot, and it is the one
place a link is wanted. It keeps its link and has no control of its own.

## 3. The settings

Client settings, not campaign rules: they change what this client says, not how the group plays.
They are not broadcast, they are not announced, and they work with no active campaign — the same
treatment `verbosity` already gets.

| Setting | Default | Effect |
|---|---|---|
| `plainItemNames` | **on** | Every item link in a group announcement becomes the name it displays: `[Thunderfury]` rather than the full link. |

It defaults **on**. A hoverable link is the better line for the humans in the raid, so this is a
real cost — but every player of this addon runs bots, the trade happens on every roll and every
award, and a default that makes the tool misbehave out of the box is worse than one that drops a
convenience. A host without the problem turns it off.

`autoEquipWinners` keeps its own default and stays settable, but has no panel control: it was
never the cause, and a tick box for it would send hosts chasing the wrong thing.

## 4. Where the strip happens

`Announce.PlainNames(text)`, pure, applied in `enqueue` — the one chokepoint every outgoing line
passes through, so a format added later cannot escape the setting by forgetting to call it.

| Decision | Reason |
|---|---|
| **The colour codes go with the link** | They wrap it. A stray `|r` left behind would recolour the rest of the line. |
| **A class-coloured player name survives** | It is a colour code with no `|Hitem:` in it. Stripping colours generally would uncolour every name in every line. |
| **Whispers are exempt** | This is the whole distinction. A link in party or raid chat is read by every bot in the group as something to act on; a whisper is a command addressed to one bot, and `equip <link>` is the form that command wants (007 §7). Stripping it there would quietly break auto-equip rather than fix anything. |

## 5. Turning it off

The tick box is in the host panel's **Raid settings**. `/rls links` reports it and
`/rls links off` sets it, for a host who would rather type than hunt for a control.

`verbosity = OFF` remains the free diagnostic for any future "a bot reacted to something"
report: it silences every announcement without touching the whispers, which separates the two
sources in one pull. That is how this one was settled.

## 6. Acceptance criteria

**Fixture (`announce` suite)**

- A coloured item link becomes the name it displays, colour codes included.
- An uncoloured link becomes its name too.
- Several links in one line are all reduced.
- A line with no link is unchanged.
- A class-coloured player name is not treated as an item link.

**In game**

- With the setting on, opening a round announces item names and no bot opens a trade.
- A delivery to the host's own bot still whispers `equip` with a full link.
- `/rls links` reports the current state and it survives a reload.
