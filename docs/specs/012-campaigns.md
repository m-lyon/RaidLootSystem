# Spec 012 — Campaigns

**Modules:** `Modules/Campaign.lua`, `UI/Campaigns.lua`, changes to `Modules/{Database,Roster,Round,Client,Comms,History,Pending,PriorityList}.lua`, `Core/Serialize.lua`, `UI/{HostPanel,HierarchyEditor,RollWindow,HistoryBrowser,PriorityViewer}.lua`
**Depends on:** 000, 001, 002, 003, 005, 006, 007, 008, 010, 011
**Player-facing description:** DESIGN §2 "Campaigns"

---

## 1. Scope

A **campaign** — a permanent, named container for loot state, so one player can belong to
several raid groups without their state from one leaking into another. Each campaign owns a
priority list, the raid leader's settings, and each member's hierarchy. Joining one is by
invitation from the master looter.

This spec also performs the **`batch` → `round`** rename (§2), because the word `session` is
needed for nothing here and the existing collision would make every sentence in this document
ambiguous.

**Out of scope:** the tier model (001), resolution (003), the priority list's own mechanics
(010). Campaigns partition that state; they do not change how any of it works.

## 2. The rename: `batch`/`session` → `round`

The codebase currently calls one loot source's roll a `session` in code and a *batch* in prose.
Both names are spent: `session` is wanted for a temporal concept it does not describe, and
running two words for one thing has already produced [`notes.md`](../../notes.md)'s "rename batch
to something else".

Both become **round**.

| Was | Becomes |
|---|---|
| `Modules/Session.lua` | `Modules/Round.lua` |
| `ns.Session` | `ns.Round` |
| `ns.Client.session` | `ns.Client.round` |
| `session.id`, `sessionId` (wire, all ops) | `round.id`, `roundId` |
| `scratch.sessionId` | `scratch.roundId` |
| `tests/fixtures/session.lua` | `tests/fixtures/round.lua` |
| `docs/specs/002-session-protocol.md` | `docs/specs/002-round-protocol.md` |
| `docs/specs/004-loot-detection-and-batching.md` | `docs/specs/004-loot-detection-and-rounds.md` |
| the word *batch* in every doc | *round* |

**"Round" never means a tie re-roll iteration.** Spec 003 §6's re-rolls stay *re-rolls*, and the
`rerolls` field keeps its name. This is the one collision the name has, and it is closed by
convention rather than left to drift.

**The sweep is not a blind replace.** Several occurrences of "session" mean a *login* session and
must survive untouched — spec 002 §11's "warn once per sender per session", spec 000 §5's version
skew rule, and `Modules/ItemInfo.lua`'s "filtering is off for the session". Read each hit.

**It lands as its own commit, before any of §3 onward.** No behavioural change, `lua tests/run.lua`
and `tests/purity.sh` green either side. `Modules/Session.lua` is renamed to `Modules/Round.lua` in
that same commit, so the path `Modules/Session.lua` is never simultaneously the old thing and the
new one.

## 3. What a campaign is

> A campaign is a namespace. It has no lifecycle beyond existing, no start, and **no end** — you
> switch between campaigns, you never finish one.

That is the whole concept, and it is deliberately smaller than it sounds. A campaign holds state;
it does not gate, schedule or summarise anything.

```lua
campaign = {
  id        = "Steve-1757155200",   -- opaque, permanent, globally unique
  label     = "Tuesday 25",         -- cosmetic; the host's label propagates
  createdAt = 1757155200,
  createdBy = "Steve",

  hierarchy = { "Steve", "Sneaky", "Smash" },   -- THIS client's ordering, for this campaign

  host      = { tierCount = 3, timerSeconds = 180, qualityThreshold = 4, lootMode = "ROLL" },
  priority  = { version = 47, seed = 1757155200, seedChars = {}, order = {}, log = {} },
}
```

`hierarchy` rather than `order`, correcting spec 001 §2's name: a campaign already contains
`priority.order`, and two adjacent fields called `order` meaning different things is a bug waiting
to be written.

### Membership is implicit

There is no member list, no invite record, no permissions model. You are in a campaign if you
have a local record of it; the raid knows you are in it because you publish `ROSTER` for it.

The priority list is already the honest answer to "who belongs here" — it contains every claimed
character in the campaign — and a parallel structure could only ever disagree with it. Explicit
membership would also need permissions to mean anything (who evicts whom?), which is machinery a
five-person friend group has no use for. **Anyone holding master looter can host a round in any
campaign they are in.**

## 4. What is scoped, and what is not

| State | Scope | Why |
|---|---|---|
| `priority` (order, seed, seedChars, log, version) | **campaign** | The point of the feature. |
| `host` (tierCount, timerSeconds, qualityThreshold, lootMode) | **campaign** | An alt run plausibly wants `tierCount = 0` where the main group wants 3. Snapping back on switch is most of the value. |
| each player's hierarchy | **campaign** | See below. |
| `roster.chars` (name → class, isSelf) | global, mutable | Class is a fact about a character, true in every campaign. |
| `roster.defaultHierarchy` | global | A template. Resolves nothing (§7). |
| `settings` (filters, verbosity, windows, minimap) | global | Preferences about the addon, not about a group. |
| `pending` | global | An undelivered item is a real object with a real 2-hour clock. It carries a `campaignId` (§14) but does not live inside one. |
| `history` | global, **tagged** | Stored once, tagged with `campaignId`; filtering is a view (008). |

### Why the hierarchy is per campaign

This is the change that cuts against spec 001 and DESIGN §2's *"you set this once… it applies to
every item, every raid"*.

In an alt run, the character that is your T1 main is sitting at home. A single global ordering
would put your alt-run main in Rest forever, in its own raid — which makes an alt campaign nothing
more than a second SK list and throws away the reason to have one.

So a campaign carries **which of your characters participate and in what order**. Exclusion falls
out of the same field: a character absent from a campaign's `hierarchy` does not participate in it.

`roster.chars` stays global because the alternative — the same character owned by different
players in two campaigns *simultaneously* — is not reachable under mod-playerbots, where a bot
lives on one account. Ownership **changing hands** (someone stops playing, someone else inherits
their bots) is a mutation of global state, not a per-campaign divergence, and is served by
unclaiming and re-claiming.

## 5. Identity

```
id = "<creatorName>-<timestamp>"
```

The same convention `round.id` uses (002 §2): unique without a GUID generator that Lua 5.1 does
not have, sortable, and human-debuggable in a log.

**The id is opaque and permanent; the label is cosmetic and mutable.** Matching campaigns on their
label would let "Tues 25" and "Tuesday 25" silently fork one group into two lists, which is the
precise failure this spec exists to prevent.

The **host's label is authoritative**. It travels on `CINV`, `OPEN` and `HI`, and a client adopts
it on receipt. There is no local override: five people privately renaming the same campaign is a
support conversation nobody should have to have.

### No default campaign

**A fresh install has no campaign at all.** The only thing that exists is the hierarchy template
(§7). The first campaign is whatever the player creates (`/rls campaign new`) or is invited into;
nothing is provisioned for them.

> **Revised.** This spec originally had a fresh install create one campaign labelled "Main". That
> gave every player a campaign they never asked for, cluttering the picker and implying a raid
> context that did not exist — and its host settings were a local default that looked
> indistinguishable from a real one synced from a host. The template alone is the honest starting
> state: it is the place you set up your roster and ordering before anyone invites you anywhere,
> and it seeds the hierarchy you take into real campaigns (§7).

**No campaign is a first-class state, not an error.** `Campaign.Active()` returns nil, and every
accessor over it — `Database.Host`, `Priority`, `Hierarchy`, `DefaultTierCount` — is nil-safe.
Screens degrade to an empty or preview state rather than failing: the hierarchy editor points at
the template, the host panel offers **New**, the priority viewer reads as unseeded. The actions
that genuinely need one — opening a round, changing a host setting, simulating — refuse with
*"create or join a campaign first"* rather than half-working.

> **Ids stay unique when one is finally made.** A well-known id like `main` would be shared by every
> unrelated group's campaign, so guesting with strangers would put you nominally inside *their*
> `main` and their `SKLIST` would overwrite yours — reintroducing the exact clobber this spec
> removes. Every campaign gets an ordinary `<playerName>-<timestamp>` id.

## 6. Joining: invitation only

**A client never joins a campaign on its own initiative.** There is no ambient detection, no
prompt fired by observing an unfamiliar id in traffic.

The master looter presses **Invite raid to campaign** in the host panel, which broadcasts `CINV`.
Every client that is not already a member shows a dialog:

> **Steve invites you to the campaign "Tuesday 25".**  ·  **[ Join ]**  **[ Ignore ]**

| Action | Effect |
|---|---|
| **Join** | Opens the hierarchy dialog (§7). Confirming it creates the campaign record and makes you a member. |
| **Ignore** | Nothing is stored. No campaign record, no ignore-list entry, no saved state of any kind. |
| **Escape / close** | Identical to Ignore. |
| **Escape on the hierarchy dialog** | Identical to Ignore — you are *not* a member. |

**Re-inviting is the entire recovery mechanism.** Because Ignore persists nothing, a misclick costs
you one more press of the host's button. That deletes a whole class of questions — how long an
ignore lasts, where ignored campaigns are listed, how you un-ignore one — and the state they would
have needed.

The host can see who is missing: `HI` carries each client's active campaign and label (§10), so the
host panel shows **`3/5 joined`** with the names of the two who have not. Re-inviting reaches only
non-members, because members dismiss `CINV` for a campaign they already have without showing
anything.

### A member with no ordering is not a state

Confirming the hierarchy dialog is what makes you a member, not pressing Join. A member whose
`hierarchy` is empty could enter nothing and would be shown no reason why, which is
indistinguishable from a broken addon and would cost someone their evening.

### Non-members and an open round

A client receiving `OPEN` for a campaign it is not in **opens the roll window read-only**, with a
banner:

> You are not in the campaign "Tuesday 25". Ask the master looter to invite you.

Not silence. "The addon did nothing and I do not know why" is the worst available outcome for a
loot tool, and the read-only window is also how a mistaken Ignore gets noticed within one boss
rather than at the end of the night.

### Opening a round with non-members present

The host is **warned, not overridden**: a dialog naming the raid members who are not in this
campaign, with **Invite them** and **Open anyway**. It does not auto-invite — joining stays a
deliberate act with a person behind it — but a host cannot disenfranchise two people without
being told.

> **This is also the fat-finger check.** A host who accidentally creates a new campaign instead of
> selecting the existing one gets `0/5 joined`, a warning naming the entire raid, and — if they
> proceed — a roll window on every screen saying nobody is in this campaign. Louder than the
> silent fork it replaces.

## 7. The hierarchy dialog

Shown on **join** and on **create**. One scrolling list of every character in `roster.chars`:

| Column | Behaviour |
|---|---|
| Checkbox | Ticked = in this campaign. Unticked characters keep their row and can be re-ticked. |
| Position | Rank among *ticked* rows only. |
| Name | Class-coloured, `you` marker on `isSelf`, as 001 §7. |
| Reorder | Drag handle plus up/down buttons, reusing `UI/HierarchyEditor`'s row widget. |

Seeded from **`roster.defaultHierarchy`**, so the default is usually right and confirming is one
click.

> **Why a global template rather than "copy the campaign you're in".** Active campaign is sticky
> (§13). If you last raided in the alt run, seeding from wherever you happen to be would silently
> hand your *alt* priorities to a new campaign, at the moment you are least likely to check.
> `defaultHierarchy` does not drift.

`roster.defaultHierarchy` resolves nothing — it is never consulted for a tier, an entry or an
award. It exists only to seed. It is edited in the hierarchy editor, which grows a campaign picker
anyway (§13), with **Default** as an entry in that picker marked as a template.

The same checkbox appears in the hierarchy editor proper, so inclusion is reachable after the fact
and a character can never become unreachable by having been unticked once.

## 8. Claims, contested and presence

`ROSTER` carries the sender's hierarchy **for one campaign** (§10), so the claim index of 001 §5
becomes per campaign as a consequence. Two rules follow.

**The claim index is rebuilt for the active campaign only.** A `ROSTER` naming any other campaign
is dropped and logged. You never need claims for a campaign you are not raiding in.

**Contested is per campaign.** Two players claiming one character in *different* campaigns cannot
affect any award, so it is not a conflict; forcing a global reconciliation would let an unrelated
campaign's bookkeeping block tonight's raid. Two players claiming one character in the *same*
campaign is a conflict exactly as 001 §5 describes, and stays non-enterable for both.

**A character you left out of a campaign is invisible there, not unclaimed.** 001 §5's unclaimed-bot
warning exists to catch an oversight; deliberately leaving your mage out of the alt run is not an
oversight, and flagging it would make every campaign nag you about every character you chose not to
bring. The warning therefore fires only for characters **present in the raid** and in nobody's
hierarchy — the case it was written for.

Presence (001 §6) is unchanged and remains global: it is a fact about the raid, not about a
campaign.

## 9. Saved variables

`schema` becomes **3**. Additions and moves to the 000 §4 schema:

```lua
RaidLootSystemDB = {
  schema = 3,

  roster = {
    chars            = { Steve = { class = "MAGE", isSelf = true }, ... },  -- global, mutable
    defaultHierarchy = { "Steve", "Sneaky", "Smash", "Locky" },             -- template only (§7)
    -- roster.order is GONE. It lives on each campaign as `hierarchy`.
  },

  activeCampaign = "Steve-1757155200",

  campaigns = {
    ["Steve-1757155200"] = {
      id = "Steve-1757155200", label = "Tuesday 25",
      createdAt = 1757155200, createdBy = "Steve",
      hierarchy = { "Steve", "Sneaky", "Smash" },
      host      = { tierCount = 3, timerSeconds = 180, qualityThreshold = 4, lootMode = "ROLL" },
      priority  = { version = 47, seed = 1757155200, seedChars = {}, order = {}, log = {} },
    },
  },

  settings = { --[[ unchanged, global ]] },
  history  = { --[[ each record gains campaignId + campaignLabel (§14) ]] },
  pending  = { --[[ each record gains campaignId (§14) ]] },
  scratch  = { roundId = "", ticks = {} },
}
```

`host` and `priority` no longer exist at the top level. Every read of them goes through
`Campaign.Active()`, and `Database.lua` keeps owning that accessor so a future scoping change stays
a single-file problem, exactly as 000 §4 requires.

**The campaign is the source of truth for how the group plays it.** `host` is not one player's
preferences that happen to be filed under a campaign; a loot mode with no campaign means nothing.
So `CFG` and `CSTATE` both *write* to `campaign.host` on every member, and whoever holds master
loot next opens their first round under the settings the group was already playing by.

Without that the mode stopped at whoever happened to hold the Blizzard loot setting. A campaign
joined by invitation is created with no `host` block at all, so the defaults filled it in and the
default is `ROLL`: hand master loot to a new person in a seeded Suicide Kings campaign and their
first round resolved by roll, with the list sitting right there and nothing saying a word.

`hierarchy` is the exception and stays local. It is this client's ordering of *its own*
characters, it is never broadcast, and it is meaningless on anyone else's machine (§7).

### Migration

**There is none.** `schema ~= 3` rebuilds defaults from scratch: `roster`, an empty `campaigns`
(§5), `history` and `pending` cleared.

> No installed base exists beyond the author's own test data, which is expendable. A migration path
> that exists but has never run against real data is worse than no migration path, because it looks
> like a safety net and is not one.

## 10. Wire protocol

One new op, added to the 000 §5 table:

| Op | Direction | Body | Purpose |
|---|---|---|---|
| `CINV` | host → all | `campaignId^label` | Invite the raid to a campaign (§6) |

The campaign id is added to the ops that establish **standing** state, as a leading field:

| Op | Body becomes |
|---|---|
| `HI` | `addonVersion^campaignId^label` |
| `ROSTER` | `campaignId^name=class~name=class~…` |
| `OPEN` | `campaignId^roundId^tierCount^secondsLeft^item~item…^lootMode` |
| `SKLIST` | `campaignId^version^seed^name~name…` |
| `CFG` | `campaignId^tierCount^timerSeconds^lootMode` |

Unchanged: `SUBMIT`, `STATE`, `RESULT`, `ROLLS`, `ABORT`, `SYNC`, `RREQ`.

> **The rule, stated once so nobody has to rederive it:** the campaign travels on the ops that
> establish standing state; **`roundId` suffices for everything inside a round.** Every op in the
> unchanged list already carries `roundId`, and that round's campaign was established by its `OPEN`,
> so no message can be misattributed. The campaign does **not** go in the envelope — it would cost
> bytes on every chunk of every message against a 180-byte payload budget, and `OPEN` with six items
> is already the message most likely to chunk.

`HI` carries the label as well as the id so the host panel can render *"Dave is in 'Alt Run'"*
rather than an opaque timestamp.

**`proto` stays at `1`.** It exists to detect skew between clients in one raid, and there is no
deployed version to be skewed against.

### Receiving a campaign-bearing message

> **A campaign-bearing message is applied to the campaign it names, if you are a member of that
> campaign. Otherwise it is dropped and logged** — except `CINV`, which is what non-membership is
> for, and `OPEN`, which opens the read-only window of §6.

This single rule is the clobber fix. A `SKLIST` from a group you are not in cannot reach your list,
because it names a campaign you do not have.

`OPEN` additionally sets `activeCampaign` to the campaign it names, for members.

## 11. Lifecycle

### Create

`/rls campaign new`, or **New campaign** in the host panel. A dialog of **campaign settings only**:

| Field | Notes |
|---|---|
| Label | Required. |
| Tier count | 0–5, default 3. |
| Timer | 15–300s, default 180. |
| Quality threshold | Rare / Epic. |
| Loot mode | Fixed at **Roll**, greyed, captioned *"seed a priority list to enable Suicide Kings"* — 010 §2 makes SK selectable only once a list exists, and a new campaign has none. |

Then the hierarchy dialog (§7). Cancelling the hierarchy dialog **abandons the campaign entirely**
— nothing is written.

Creation is **local and unannounced**. A campaign does not exist for anybody else until a host
opens a round in it or invites the raid to it.

> Nothing personal belongs in the create dialog. A hierarchy is a *user* choice and a campaign's
> settings are a *raid leader* choice; the join path proves the point, since every other member sets
> a hierarchy for this campaign having never seen the create dialog at all.

### Rename

Host only, propagating on the next `CINV` / `OPEN` / `HI`. Announced to raid chat, like every other
host-visible change (010 §10).

### Delete

Confirmed with a dialog **naming what is lost** — *"Delete 'Alt Run'? Its priority list of 23
characters and 140 logged changes cannot be recovered."*

| Rule | Reason |
|---|---|
| Refused while any `pending` record names it | An in-flight item with a live clock whose failure path needs the very list it would restore into (§14). Refused outright, not warned about. |
| Refused while a round is open in it | The round resolves against this campaign's list and its award restores into it, and every close path reads its host settings. A round already closed or aborted blocks nothing. |
| The active campaign **may** be deleted | You land in whatever campaign remains, or in none at all (§5). The confirmation already names what is lost, so a second "switch away first" step bought nothing but friction. |
| Your last campaign **may** be deleted | No campaign is a supported state, not a broken one; the editor falls back to the template and the host panel offers **New**. |
| **History survives untouched** | A deleted campaign does not un-happen the awards it made. Records keep their `campaignId` and their `campaignLabel`, and the browser shows the campaign with a `deleted` marker. |

Deleting the campaign you are in repoints `activeCampaign` to the oldest remaining campaign, or to
none, and resets the published-claim index — claims are per campaign (§8), so the index the deleted
one built says nothing about where you land.

## 12. Export and import

The recovery path for a **fork** — a host who reinstalls and regenerates an id for what everyone
else knows as the same campaign, or two people who create "Tuesday 25" independently before
noticing.

Same UX as the roster export of 001 §8: a button producing a selectable string, and a paste box.
Same `Core/Serialize` encoding, prefixed `RLSC1:`. The payload is the campaign **id**, label,
`host` settings and full `priority` (order, seed, seedChars, version, log). It does **not** carry
anyone's `hierarchy`, which is personal and per client.

| Case | Behaviour |
|---|---|
| Id not present locally | Creates the campaign, then the hierarchy dialog (§7). |
| Id already present locally | **Refused unless confirmed as an overwrite**, with a dialog comparing stored and incoming version. This is the fork repair. |
| Malformed string | Rejected whole; no partial import, as 001 §8. |

> **No merge, ever.** Reconciling two divergent priority lists has no correct answer — you would be
> inventing an order and announcing it as authoritative, which 010 §10 identifies as the single
> thing that ends a group's trust in the list. Repair is "everyone import the copy that is right",
> which is a decision a person makes and the addon executes.

## 13. UI

| Surface | Change |
|---|---|
| **Host panel** | A **Campaign** section: active campaign and label, a switcher, `N/M joined` with the names of non-members, and **Invite raid to campaign**, **New**, **Rename**, **Delete**, **Export**, **Import**. Every existing host setting in the panel now reads and writes the active campaign's `host` table. |
| **Hierarchy editor** | A campaign picker in the header, listing every campaign plus **Default** (the §7 template, marked as such). The picker is **prominent, not decorative** — editing the wrong campaign's hierarchy is a silent no-op you would discover next Tuesday. Rows gain the §7 inclusion checkbox. |
| **Roll window** | The campaign label in the title. The read-only non-member banner of §6. |
| **History browser** | Defaults to filtering by active campaign, with an **All campaigns** toggle and a `deleted` marker on records whose campaign is gone. |
| **Priority viewer (011)** | Renders the **active campaign's** list; its header gains the campaign label, so a screenshot is unambiguous about which list it shows. |
| **Minimap** | No change. Switching campaigns is deliberate and belongs behind a window, not one click from the map button. |

### Commands

```
/rls campaign                      list, marking the active one
/rls campaign new <label>
/rls campaign switch <n>
/rls campaign rename <label>
/rls campaign delete <n>
/rls campaign invite               host only; sends CINV
/rls campaign export
/rls campaign import <string>
```

### Active campaign is sticky

After a raid, your active campaign stays whatever you last raided in. It does **not** revert to a
previous selection.

> Reverting would mean that ten minutes after the raid, when you go to reorder your hierarchy off
> the back of what just happened, you are silently editing a *different* campaign's hierarchy. The
> edit would appear to save and would have no effect next Tuesday. Sticky is surprising once;
> reverting is quietly wrong forever.

## 14. Interaction with existing specs

**010 §6, restore-on-failure.** A `pending` record gains `campaignId`, and a restore targets **that**
campaign's list regardless of which is active. The 2-hour trade window will routinely outlive a
campaign switch, and restoring into whatever happens to be active would corrupt an unrelated list
— a corruption invisible by inspection, which 010 §6 already identifies as the worst bug this
feature could ship.

**008, history.** Each record gains `campaignId` and `campaignLabel` (the latter so a deleted
campaign still renders a name). Both appear in the text and CSV exports.

**002 §9, `ML_CHANGED`.** Unchanged. A master-looter change mid-round aborts the round on every
client exactly as today; the new host then opens rounds in **their** active campaign, which may
differ and may need invites. No migration of campaign state between hosts, for the same reason
002 §9 refuses to migrate a round: state recovery bugs in a loot addon cost people items at the
worst possible moment.

**009, simulation.** `/rls simulate` runs against the active campaign's settings and a copy of its
priority list, as it does today. A new `scenario=campaign` exercises invite → join → hierarchy
dialog → round with a non-member present.

**011, priority viewer.** Reads the active campaign (§13). No other change; the row model stays
pure.

## 15. Acceptance criteria

**Rename (§2), before anything else**

- `lua tests/run.lua` and `tests/purity.sh` pass identically before and after, with no behavioural
  diff.
- No occurrence of `session` remains in code except those meaning a login session.
- `git grep -i batch -- . ':!docs/specs/012-campaigns.md'` returns nothing. This spec's §2 keeps the
  word because it is the document explaining the rename.
- [`notes.md`](../../notes.md)'s "rename batch to something else" is struck off.

**Pure (`campaign` suite)**

- `Campaign.New(label, settings)` produces an id of the form `<name>-<timestamp>` and a record
  validating against §3.
- Encode → decode round-trips a campaign export, including a 200-event `priority.log`.
- A campaign-bearing message naming an unknown id is rejected by the membership predicate; one
  naming a known id is accepted.
- Ticking and unticking in the hierarchy model yields positions numbered over ticked rows only.

**State**

- A `SKLIST` naming a campaign the client is not in leaves the stored list **and its log**
  byte-identical. This is the regression test for the bug this spec exists to fix.
- Two campaigns each hold an independent list: a suicide in one leaves the other's version and
  order untouched.
- Switching campaigns swaps `tierCount`, `timerSeconds`, `qualityThreshold` and `lootMode` to that
  campaign's values, and the hierarchy editor to that campaign's hierarchy.
- Deleting a campaign with a pending delivery is refused; the same delete succeeds once the
  delivery resolves, and history keeps both records.
- A pending delivery that fails terminally after a campaign switch restores the winner's index in
  the campaign the award was made in, not the active one.

**Joining**

- A client not in a campaign receiving `OPEN` for it opens a read-only roll window naming the
  campaign, and submits nothing.
- Ignore writes nothing to saved variables; `/reload` leaves no trace of the invitation.
- A second `CINV` after an Ignore shows the dialog again; a `CINV` for a campaign the client is
  already in shows nothing.
- Cancelling the hierarchy dialog leaves the client a non-member.
- Opening a round with a non-member present warns the host and names them.

**Import**

- Importing a campaign the client already has is refused without confirmation, and the confirmed
  overwrite reproduces the exporter's order, version, seed and log exactly.

**`/rls simulate`**

- `scenario=campaign` runs invite → join → round with one non-member, and the non-member's window
  is read-only throughout.
