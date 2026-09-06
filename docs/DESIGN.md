# Raid Loot System — Design

> **Status:** design agreed, not yet implemented. This document is for players to read and
> review. It describes *what the addon does and why*, not how it is built. Implementation
> detail lives in [`docs/specs/`](specs/).

---

## 1. The problem

Our raid is a small number of real players, each of whom also controls several bots. Every
character in the raid — human or bot — needs gear, but the bots cannot advocate for
themselves. That leaves the humans to negotiate loot on behalf of a roster of characters they
own, which in practice means a long, ad-hoc conversation after every boss.

Existing roll addons (RaidRoll and friends) assume one human, one character, one roll. They
have no concept of "these four characters all belong to Steve, and Steve cares about them in
this order". Raid Loot System is built around exactly that idea.

## 2. Core concepts

### Characters and rosters

Every player declares a **roster** — the characters they own and speak for. That includes the
character they personally play and every bot under their control. Rosters are self-declared
and account-wide: you set yours up once and it follows you.

A character can only belong to one roster. If two people claim the same bot, the addon shows
the conflict rather than quietly picking a side.

### The hierarchy

Your roster is not a flat list. It is an **ordered** one — your personal statement of which of
your characters you most want geared.

> Steve's hierarchy: **1.** Mage (his own character) · **2.** Rogue · **3.** Warrior · **4.** Warlock

You set this once, and you can change it whenever you like. It applies to every item, every
raid, until you change it.

### Tiers, and how many of them count

The raid leader sets a **tier count** for the raid — how many positions in your hierarchy are
treated as distinct priorities. The default is **3**.

With a tier count of 3, Steve's hierarchy resolves like this:

| Position | Tier | Meaning |
|---|---|---|
| Mage | **T1** | Highest priority |
| Rogue | **T2** | |
| Warrior | **T3** | |
| Warlock | **Rest** | Shares the bottom tier with everything below position 3 |

Everything below the cut-off collapses into a single **Rest** tier where all characters are
equal. If Steve had nine characters, positions 4 through 9 would all sit in Rest together.

> Rest is a flat lottery under the default **Roll** mode. Under **Suicide Kings** (§9) it is
> still a single bucket, but the winner inside it is decided by list position rather than by a
> roll. Either way, every character below the cut-off is equal *as far as the hierarchy is
> concerned*.

Lowering the tier count does not destroy your ordering — the addon always stores your full
list, so if the raid leader raises the count from 3 to 5 next week, your 4th and 5th positions
come back exactly as you left them.

A tier count of **0** is legal and means "no priorities at all — everything is a flat raid
roll".

### Ranks are absolute

This is the most important rule in the system, and it has a consequence worth understanding
before you agree to it.

Your tier is fixed by your hierarchy. It does **not** shift depending on which characters you
happen to enter for a given item. If Steve enters only his Warrior for a plate item, that
Warrior competes as a **T3** entry — it is not promoted to T1 just because Steve's higher
characters weren't entered.

**What this means in practice:** Steve's main is a Mage, so Steve will never have a T1 entry
for a plate item. His Warrior will always fight in the lower tiers against other people's
alts, while a player whose main *is* a Warrior takes plate at T1 more or less uncontested.

That is deliberate. The system encodes a simple, honest policy — **mains eat first, alts fight
over the rest** — and it is the only version where the hierarchy is a promise you make once
rather than a negotiation you reopen for every item. The alternative (a separate hierarchy per
armour type) is on the roadmap if this turns out to sting in practice.

## 3. A raid night, end to end

**Before the raid.** Each player opens the hierarchy editor, claims their characters, and drags
them into their preferred order. This is a one-time setup; most nights nobody touches it.

**The boss dies.** The master looter opens the corpse. Raid Loot System notices the epics and
opens a **batch** — a single roll covering everything the boss dropped at once, rather than
six separate rounds. A 3-minute timer starts, and the items are announced in raid chat.

**Everyone enters.** Each player gets one window: their characters down the side, the boss's
items across the top, a checkbox in every cell. Cells are greyed out where that character
can't use that item, so a plate drop lights up only your plate wearers. Each row carries a
tier badge so you can see the stakes without having to remember your own ordering. You tick
what you want, and hit **Submit** once for the whole board.

**Everyone can see everything.** Once you submit, your entries are visible to the whole raid,
and you can revise them until the timer ends. There is no hidden information — the system
works on people being reasonable with each other, and openness is what makes that possible.

**Resolution.** When the timer expires — or when the master looter closes it early, which is
what usually happens once everyone's in — the addon resolves each item independently:

1. Take the highest tier that has any entries for this item.
2. Roll 1–100 for every entry in that tier.
3. Highest roll wins. Exact ties are re-rolled among the tied entries only, announced as such.
4. Nothing in a lower tier is even consulted unless the tier above it is empty.

The result is announced in chat and shown in full to everyone: every entry, its owner, its
tier, its roll. Nothing about how the winner was chosen is hidden.

**Handover.** The master looter clicks once and the item goes from the corpse straight to the
winner. If the winner is a bot, the addon then tells that bot to equip what it just won, so
you aren't whispering six equip commands after every boss.

## 4. The rules in full

### Who can be entered

- Only characters **currently in the raid**. You cannot roll for someone who isn't there — the
  loot would have nowhere to go.
- Only characters who can **actually use the item** (armour type, weapon type, class
  restrictions). This filter is on by default and can be overridden per entry for off-spec and
  judgement-call cases.
- Tier tokens are handled properly: a *Chestguard of the Lost Conqueror* is not equippable by
  anyone, so it is matched against its redeeming classes instead. Items the addon can't
  classify at all — mounts, patterns, mats — turn the filter off entirely and your whole
  roster becomes enterable.

### How many characters you can enter

As many as you like. There is no cap, including in the Rest tier — if six of your bots are
eligible for an item, all six can roll, and each of them rolls individually.

### Duplicate drops

If a boss drops two copies of the same item, that's **one** roll with two winners, taken from
the same tier-then-roll ordering. The second copy goes to the runner-up, dropping into a lower
tier if the top tier only had one entry. Two different characters always win the two copies;
they may both belong to the same player if that player's entries genuinely placed first and
second.

### Nobody entered

An item with zero entries is marked **unclaimed** and handed back to the master looter as a
free choice. It's recorded as unclaimed in the history so the outcome isn't invisible.

### The timer

3 minutes by default, adjustable by the raid leader between 15 seconds and 5 minutes. It's a
ceiling, not a target — the master looter can close it early the moment everyone has
submitted, and the window shows a live `4/6 submitted` counter so you know when that is.

## 5. Getting the item to the winner

Loot **stays on the corpse** while the roll runs. That matters: an item handed out from the
corpse binds directly to the winner and there's no deadline on it.

When the master looter needs to move on, or the winner is out of range, or the corpse is about
to despawn, there's an escape hatch — the master looter loots the item themselves and trades
it over afterwards. This works because WotLK gives you a **2-hour window** to trade
bind-on-pickup items to people who were eligible for that kill. It's fully supported, but it
starts a clock, so anything sitting in someone's bags awaiting handover appears in a **pending
deliveries** list with a countdown, and the addon reminds you at login if you're still holding
something that isn't yours.

## 6. What the raid leader controls

| Setting | Default | Range |
|---|---|---|
| Tier count | 3 | 0–5 |
| Entry timer | 180s | 15–300s |
| Quality threshold for auto-added items | Epic | Rare or better |
| Chat verbosity | Summary | Off / Summary / Verbose |
| Loot mode | Roll | Roll / Suicide Kings |

**Roll** is the original behaviour: highest roll in the highest occupied tier. **Suicide Kings**
replaces the roll with a persistent priority list — see §9. It can only be selected once the list
has been seeded, and like the tier count it changes only between batches, with an announcement.

The tier count can be changed mid-raid, but only between batches, never while a roll is open —
and the change is announced.

## 7. What each player controls

- Their roster and its ordering.
- Whether the "can actually use it" filter is applied to their entries.
- Whether bots are automatically told to equip what they win.
- Minimap button and window positions.

Rosters and hierarchies can be exported to a text string and imported elsewhere, so a
reinstall doesn't mean retyping nine characters in order.

## 8. History

Every batch is recorded: what dropped, who entered, what tier they were, what they rolled, who
won, and whether the handover actually completed. Both the master looter and every player keep
their own copy. It can be exported as plain text or CSV.

Under Suicide Kings it also records the priority list as it stood when the roll opened, so an
argument about a past award is settled by looking it up rather than by remembering.

The log is deliberately richer than v1 needs, because it's the raw material for anything we
build later — per-bot gearing statistics, attendance, sniping patterns.

## 9. Suicide Kings

An alternative to rolling, chosen by the group in
[proposal 001](proposals/001-loot-fairness.md). Off until the raid leader seeds the list and
switches the mode on.

**The list.** One ordered list containing **every character** in every roster — yours and
everyone's bots. It is shuffled once, from a published seed, and then it lives forever.

**Winning an item.** Tier gating works exactly as before: a T1 entry still beats a T2 entry,
always. But inside a tier, there is no roll — **the character highest on the list wins.** That
character then drops to the **bottom**, and everyone below it moves up one.

That is the whole system. Three things follow from it:

- **Nothing is random.** You can look up who will win before you tick a box. Disputes end by
  pointing at a number.
- **Waiting is the only way to gain priority.** Losing costs you nothing. Not entering costs you
  nothing. Your position improves purely by not having won recently.
- **Characters are independent.** Your mage winning sinks your mage. Your rogue keeps its place,
  so gearing your bots never costs your main its priority.

**Characters not in the raid don't move.** A bot left at home doesn't drift up the list while
everyone else is raiding.

### Two rules a boss-at-a-time system needs

Classic Suicide Kings hands out one item at a time. We resolve a whole boss at once, and your
character has one position but six items to want.

1. **One win per character per batch.** Once a character wins, it's out of the rest of that
   boss's items. Otherwise being top of the list and ticking everything wins you everything, for
   the price of one suicide.
2. **The priority pick.** Star **one** of the items you ticked for that character. If it would
   win more than one, the star decides which. Starring costs you nothing — it only ever applies
   when you'd have won several anyway — and without it you win the junk ring in the first loot
   slot and lose the weapon in the fourth.

### What it costs

**The guarantee only holds inside a tier.** Suicide Kings normally promises: *wait long enough,
reach the top, and the next thing you want is yours.* Because we keep the tier gate, that holds
only among characters in the same bucket. If your main is the raid's only warrior, you take every
plate item at T1 forever, however far down the list you fall.

What limits it: **an uncontested win still suicides you.** You keep the plate nobody else can
use, but you fall down the list and stop winning the things several people want — tokens,
weapons, trinkets. The list works where people are actually competing.

**And ticking a box is still free.** Because positions are per character rather than per player,
entering an item spends that character's place and nothing else. Suicide Kings is often described
as making every entry a hard choice; in this variant it isn't one.

### When something goes wrong

If an award fails to arrive — you disconnect, the trade never happens — **your position comes
back.** You are never suicided for an item you didn't receive.

The raid leader can reseed, reorder and manually correct the list. Every such change is announced
in raid chat and recorded, because a priority list edited quietly is worse than no list at all.

## 10. What this deliberately does not do

These were considered and left out on purpose. They're on the [roadmap](ROADMAP.md) with the
reasoning attached, so we don't re-argue them every month.

- **No mainspec/offspec flag.** The hierarchy already expresses priority; a second, orthogonal
  axis would double the resolution rules to say something you can already say.
- **No per-armour-type hierarchies.** One ordering, applied to everything. See §2 for the
  tradeoff this accepts.
- **No gear-based upgrade filtering.** The addon won't tell you whether an item is actually an
  upgrade for a bot. PlayerbotManager already tracks that data and integrating the two is a
  separate piece of work.
- **No anti-sniping lockout.** With open entries and a 3-minute timer, you *can* wait until
  2:55 and submit once you've seen what everyone else did. The addon records submit and revise
  timestamps so the behaviour is visible, but it doesn't mechanically prevent it. We're relying
  on people being reasonable.
- **No entering on someone else's behalf.** You enter your own characters, nobody enters for
  you. A bot nobody has claimed simply can't be entered, and the master looter sees a warning
  so it gets fixed.
- **No points, DKP or EPGP.** Rolls, or the priority list.
- **No item weighting.** Under Suicide Kings a ring and a weapon both cost one suicide. Weighing
  items by GearScore was considered and rejected: it turns the list into a soft points system and
  destroys the one thing it's good at, which is that you can predict it. See
  [proposal 001](proposals/001-loot-fairness.md) §3.
- **No memory of past loot under Roll mode.** If the group runs Roll rather than Suicide Kings,
  every item is an independent lottery and a player who won three things tonight is treated
  exactly like one who won nothing.

## 11. Glossary

| Term | Meaning |
|---|---|
| **Roster** | The set of characters one player owns and speaks for |
| **Hierarchy** | A player's ordering of their roster, highest priority first |
| **Tier** | A priority band derived from hierarchy position and the raid's tier count |
| **Rest** | The single bottom tier holding everything below the cut-off, all equal |
| **Tier count** | How many hierarchy positions are treated as distinct tiers. Raid leader's setting |
| **Batch** | One roll covering every item from a single loot source |
| **Entry** | One character submitted for one item |
| **Host** | The client running the batch. Always whoever holds master looter |
| **Loot mode** | Roll or Suicide Kings. Raid leader's setting |
| **Priority list** | The Suicide Kings order — every character, highest priority first |
| **Suicide** | Dropping to the bottom of the priority list after winning an item |
| **Priority pick** | The one item a character stars, deciding which it spends its position on |
