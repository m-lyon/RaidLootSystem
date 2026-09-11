# Spec 013 — Campaign tier roster

**Modules:** `Core/TierRoster.lua`, `UI/TierViewer.lua`, additions to `Modules/Campaign.lua`,
`Modules/Roster.lua`, `UI/PriorityViewer.lua` and `Modules/PriorityList.lua`
**Depends on:** 000, 001, 003, 010, 011, 012

## 1. Scope

Make the tier assignment a **property of the campaign**, stored and readable, and show who
composes each tier.

- Each member's submitted hierarchy is recorded on the campaign record it was submitted for.
- A pure model turns those orderings plus the campaign's tier count into tier bands.
- A new read-only window, `/rls tiers`, shows the bands for a campaign.
- The two priority-list surfaces — the host panel's section (010 §10) and the viewer (011) —
  group their rows into the same bands.

**Out of scope:**

- **Resolution is unchanged.** 003 §5 already walks buckets in ascending tier and never consults
  a lower tier while a higher one can supply a winner. This spec adds no rule to the engine and
  changes no outcome.
- **Editing anyone else's hierarchy.** The roster is a read of what each member submitted. The
  only screen that writes a hierarchy is that member's own editor (001 §7).
- **New wire ops.** `ROSTER` already carries the ordering and each character's class, which is
  everything a band needs.
- The tier count itself, which is a host setting on the campaign (012 §9).

## 2. Why this exists

A tier is the **first** gate on every item under both loot modes. It decides which bucket you
compete in before the list index or a roll decides anything inside that bucket, so the single
most consequential fact about a campaign is who sits in T1.

That fact is currently unreadable, and worse, unstored:

| Today | Consequence |
|---|---|
| A member's ordering arrives as `ROSTER` and is held in a module table keyed by player | It is lost on reload, wiped on a campaign switch, and empty until someone triggers a re-request |
| `ROSTER` naming any campaign but the active one is dropped outright | A player in two campaigns holds tiers for at most one of them |
| Nothing is written to saved variables | The tier roster does not exist outside a live raid, which is exactly when a group would want to look at it |
| The viewer shows a per-row tier badge and nothing else | You can read one character's tier; you cannot read what a tier contains |

So the campaign owns a tier *count* but not the tier *assignment*, and the assignment is
reconstructed from live chatter each session. The sentence a group wants to be able to say —
*"Matt, Stewart and Craig joined this campaign and submitted their hierarchies, so this is what
T1 holds"* — is not true of the data today. This spec makes it true.

Nothing new goes on the wire. This is storage and presentation over a message every client
already broadcasts and every client already receives.

## 3. Storage

Each campaign record gains `members`:

```lua
campaign.members = {
  ["Matt"]    = { order = { "Matt", "Matthbot", "Matthpal" },
                  chars = { Matt = { class = "WARRIOR" } },
                  at    = 1757155200 },
  ["Stewart"] = { },
}
```

| Decision | Reason |
|---|---|
| **Additive, no schema bump** | `Campaign.Normalise` already fills in what a stored campaign is missing, so `members = {}` appears on every existing campaign for free. A bump would rebuild the saved variables empty (012 §3) and take every group's priority list with it — an unacceptable price for a display feature. |
| **Keyed by player, written only from that player's own `ROSTER`** | Authority is unchanged from 012 §7: a hierarchy belongs to the member who submitted it. The host's stored copy is a **cache of what was broadcast**, never a source the host can edit, and `CFG` / `CSTATE` still leave hierarchies alone. |
| **`at` is stored** | A tier built from an ordering submitted three weeks ago is still a fact worth showing, but a reader must be able to tell it from one submitted tonight. |
| **`chars` is stored with the order** | It carries class, which the roster needs for colouring and which would otherwise be unavailable for a member who is offline. |

### The one behavioural change

`ROSTER` is currently dropped unless it names the **active** campaign. It is now **recorded into
whichever campaign it names, provided you are a member of that campaign**; a `ROSTER` for a
campaign you are not in is still dropped and logged, per 012 §10.

The claim index is untouched by this. `Roster.claims` continues to be rebuilt for the active
campaign only, exactly as 012 §8 requires — two players claiming one character in unrelated
groups must not read as a conflict. Recording and claiming are now separate steps: the record is
per campaign, the claim index is for the one you are raiding in.

## 4. The model is pure

`Core/TierRoster.lua`. Plain tables in, plain tables out, no WoW API.

```lua
TierRoster.bands(members, tierCount, ctx)   -- ctx = { present, listIndex, me }
```

`members` is an array of `{ player, order, chars, at }`. The return is an array of bands, one per
tier in play plus `Rest`, each `{ tier, label, rows }`, where a row is `{ char, owner, class,
position, present, isSelf, listIndex, at }` and `position` is the character's index in **its
owner's** order.

A band is emitted even when empty, so a campaign where nobody has reached T3 still shows T3 as a
band with nothing in it rather than silently renumbering the tiers below it.

| Decision | Reason |
|---|---|
| **Bands are derived, never stored** | The tier count is a host setting that changes, and a member can resubmit at any time. A stored band list would be a second copy of a derivation and would go stale silently. |
| **Rows sort by owner name inside a band** | The roster answers *who composes this tier*, and owner order is stable across tier-count changes and readable by a person scanning for a name. |
| **`Tiers.forPosition` is the only tier arithmetic** | 001 §3 and 000 §6 already say nothing else derives a tier. This spec derives none of its own. |

## 5. The window

`UI/TierViewer.lua`, opened by `/rls tiers` with no argument -- `/rls tiers <0-5>` still sets
the count a host raids with, because choosing how many tiers there are and reading who is in them
are the same subject. Also a **Tiers** button on the host panel's Campaign section. Read-only, for every player, like
the priority viewer (011 §1).

It shows the campaign label and its tier count, then one section per band, each listing its
characters with owner, class colour and presence. Below the bands, the two facts that decide
whether the roster can be trusted:

- **Who has not submitted** — a member announcing this campaign who has no stored ordering. Named,
  not counted: "not submitted: Craig" is actionable, "2 of 3 submitted" is not.
- **How old each stored ordering is**, on the row tooltip, from `at`.

Sourced from campaign membership, **not** from the priority list, so it works under `ROLL` and
before any list is seeded — which is when a group is most likely to be arguing about tiers.

## 6. Bands on the priority-list surfaces

The host panel section and the viewer keep their list order and their position numbers, and gain
a band header before each tier's run of rows.

| Decision | Reason |
|---|---|
| **Rows sort by list index inside a band** | That is precisely the order 003 §5 awards in: buckets ascending by tier, list index ascending inside a bucket. The banded list is therefore a readable statement of who wins next, not a decoration. |
| **The position number stays on every row** | It is the number people came to read (011 §3), and a suicide is announced in terms of it (010 §10). |
| **An `unknown` band collects characters whose owner has submitted nothing** | Rendering them as `Rest` would be a lie with the same shape as the truth. A named band says the data is missing. |
| **The host panel's move controls act on list position, unchanged** | Bands are a grouping of the same rows. Moving a character within a band or across one is the same single-step move on the list it always was. |

## 7. Acceptance criteria

**Fixture (`tierroster` suite)**

- Three members with orderings of 3, 5 and 1 characters at `tierCount = 3` produce bands T1, T2,
  T3 and Rest, where T1 holds exactly the three first-ranked characters.
- A member with one character appears in T1 and in no other band.
- `tierCount = 0` produces a single `Flat` band holding every character.
- A member with an empty ordering contributes no rows and does not error.
- A tier nobody has reached is emitted as an empty band rather than omitted.
- Rows inside a band sort by owner name, and the same input in a different `members` order gives
  an identical result.
- With `ctx.listIndex` supplied, rows carry it, and band order by list index matches what 003 §5
  would award.
- A character claimed by nobody in `ctx` still lands in its owner's band.

**Fixture (`campaign` suite)**

- `Campaign.Normalise` fills `members = {}` on a stored campaign that predates this spec, leaving
  its priority list, log and host settings untouched.
- Recording a hierarchy stores order, chars and `at`, and recording again replaces it rather than
  merging.

**`/rls simulate`**

- Three simulated members publish, and `/rls tiers` names all three in T1.
- A reload leaves the roster intact, with no republish.
- Switching campaigns switches the roster, and switching back restores the first one's bands
  without a re-request.
- Seeding a list and opening an SK round leaves the banded viewer's rows in the order the round
  awards in.
