# Roadmap

Features considered during design and deliberately left out of v1. Each entry records **why**
it was deferred, so the decision doesn't get re-argued from scratch every month.

Nothing here is rejected forever. If a v1 assumption turns out to be wrong in practice, the
relevant entry below is the thing to promote.

---

## Per-armour-category hierarchies

**What:** instead of one global ordering, keep a separate ordering per armour class (cloth /
leather / mail / plate) or per slot category, so your Mage is T1 for cloth and your Warrior is
T1 for plate.

**Why deferred:** v1 accepts the skew this creates (see DESIGN §2, "Ranks are absolute"). One
global ordering is a single, explicable policy — *mains eat first* — and it keeps the
hierarchy editor to one list.

**Promote if:** players with a cloth main find their plate alts never win anything, and it
demonstrably suppresses participation.

**Cost:** this is a **data-model change**, not a UI change. `roster.order` becomes a map of
category to ordering, and every tier derivation has to take the item's category as an input.
Spec 001 and spec 003 both change. Migration required for existing saved variables.

---

## One-entry-per-player-per-tier fairness cap

**What:** a raid-leader toggle limiting each player to a single entry in any given tier, so a
player with eight bots doesn't get eight lottery tickets in Rest.

**Why deferred:** our group has roughly equal bot counts, so the imbalance the cap protects
against doesn't exist. Adding an unused toggle is pure surface area.

**Promote if:** roster sizes diverge significantly.

**Cost:** low. It's a filter applied to the tier bucket inside the resolution engine plus one
setting. Spec 003 and spec 006.

---

## Gear-aware upgrade filtering

**What:** a third eligibility filter — only show a character as enterable if the item is
actually an upgrade over what it currently has equipped.

**Why deferred:** requires per-bot equipped-gear data, which means either doing our own
inspection scanning or integrating with PlayerbotManager, which already maintains exactly this
(iLvL, GearScore and 17 gear slots per bot). Either route is a substantial piece of work with
its own failure modes, and v1 works fine without it.

**Promote if:** people are routinely entering bots for sidegrades and wasting rolls.

**Cost:** medium-high. New data source, cache invalidation, and a hard dependency or an
optional integration layer. Its own spec.

---

## Mainspec / offspec as per-entry tier demotion

**What:** flag an entry as offspec, dropping it a tier (or straight to Rest) for that item only.

**Why deferred:** the hierarchy already expresses priority. A second, orthogonal axis doubles
the resolution rules — is an MS-Rest above or below an OS-T1? — to say something you can
already say by where you put the character or by not entering it.

**Promote if:** people are asking for a way to say "I want this, but not as much as my ranking
implies" often enough that not-entering isn't a good enough answer.

**Cost:** low-medium, *if* implemented as a demotion rather than a second axis. Demotion keeps
the comparison one-dimensional. Spec 003 and spec 005.

---

## Anti-sniping lockout

**What:** freeze submissions and revisions for the final N seconds of the entry window, so
nobody can wait to see the full field before committing.

**Why deferred:** v1 chose fully-open entries on the basis that the group polices itself. The
history log already records submit and revise timestamps, which makes persistent sniping
visible as a fact rather than a suspicion.

**Promote if:** the timestamps show it's actually happening.

**Cost:** low. One host-side rule plus a countdown state in the roll window. Spec 002 and 005.

---

## Host-proxy entry for players without the addon

**What:** let the master looter enter on behalf of a raid member who isn't running Raid Loot
System, or is running an incompatible version.

**Why deferred:** our group is small enough that everyone runs the same version. Proxying
breaks the clean one-way ownership model — *you enter your own characters, nobody enters for
you* — which is much easier to reason about and to explain.

**Promote if:** the raid grows, or version drift becomes routine.

**Cost:** medium. Needs an "entered by" provenance field on entries, host-side UI for it, and
careful thought about what it means for the openness guarantees. Spec 002, 006.

---

## Raid-leader session-claiming of unclaimed bots

**What:** let the raid leader temporarily claim a bot nobody has declared, for the duration of
one raid, so its loot isn't stranded.

**Why deferred:** same reasoning as host-proxy entry, and paired with it — if either lands,
both should. In v1 an unclaimed bot simply can't be entered and the host panel warns about it,
which takes ten seconds to fix properly.

**Promote if:** unclaimed bots turn out to be common rather than an occasional oversight.

**Cost:** low-medium, and shares most of its machinery with host-proxy entry. Spec 001, 006.

---

## History-driven priority decay

**What:** use the loot history as an input to resolution — e.g. a character that has already
won twice tonight is demoted, or accumulates a soft penalty across the tier.

**Why deferred:** it's a significant change to the fairness model and needs a season of real
history to design against. v1 logs richly precisely so this is buildable later without
retroactively missing fields.

**Promote if:** the raw roll system visibly concentrates loot on a few lucky characters over a
tier's worth of raiding.

**Cost:** high. Resolution stops being a pure function of the current batch, which weakens the
testability guarantee in spec 003 unless history is injected as an explicit input. Design it
as an injected parameter, not a global read.

---

## Points systems (DKP / EPGP)

**What:** earned-currency loot distribution instead of rolls.

**Why deferred:** not what this group wants. RaidRoll_EPGP exists if anyone changes their mind.

**Promote if:** the group's loot culture changes fundamentally — at which point this is
probably a different addon, not a feature of this one.
