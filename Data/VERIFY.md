# Verifying the data tables

`Data/ClassArmor.lua`, `Data/TierTokens.lua` and `Data/ItemClasses.lua` are the files
CLAUDE.md marks **verify, don't recall**. They were assembled from reference material and
**have not been checked against a live 3.3.5a server.**

`Data.WEAPONS_VERIFIED` is now `true`: the weapon rows below were checked in game.
`Data.SUBCLASS_ORDER_VERIFIED` is now `true` too — see the last section.

## Why this matters, and how much

A wrong entry makes one class ineligible for one weapon category — or wrongly eligible for it.
It is not catastrophic and it is not silent:

- the roll window shows the reason code on the disabled cell (spec 005 §3),
- any player can right-click to override a weapon or armour check (spec 003 §8),
- the raid leader can disable the eligibility filter entirely (spec 006 §3).

So a bad row costs one annoyed person one right-click, not a lost item. That is the reason it
was acceptable to ship the table unverified rather than block on a raid night — but it is not a
reason to leave it unverified.

## The armour table

**Settled**, and as of v0.4.0 it is a *rank* model rather than one armour type per class:
`CLOTH < LEATHER < MAIL < PLATE`, each class has a ceiling, and a class is eligible for its own
type and everything below it (spec 003 §8 check 6).

The previous strict mapping — *the armour class this class should be competing for at level 80* —
was reported wrong on a raid night: Shamans and Rogues were filtered off cloth. Who *should* get
an off-piece is a tier and roll question, not an eligibility one; the filter now only excludes
armour a character genuinely cannot equip.

The only thing worth re-checking is `Data.ARMOR_SLOTS`. It must contain the eight true armour
slots and **nothing else**. Cloaks, rings, necks and trinkets report an armour subclass but are
wearable by everyone, and including `INVTYPE_CLOAK` here would make every cloak in the game
cloth-only.

## The weapon table — verified

Checked in game on **2026-09-06** by Matt Lyon against the group's AzerothCore + mod-playerbots
server (build not recorded). Each line below was confirmed by inspecting the item on a character
of that class. The `eligibility` suite carries one fixture case per line, so a later edit that
undoes any of them fails CI.

| Class | Confirmed | Table |
|---|---|---|
| Hunter | can equip thrown | **was wrong** (excluded); fixed, `THROWN` added |
| Paladin | can equip polearms | included, unchanged |
| Druid | can use polearms | included, unchanged |
| Shaman | cannot use polearms | excluded, unchanged |
| Warrior | can use staves, shields and thrown | included, unchanged |
| Warlock, Mage, Priest | can use daggers | included, unchanged |
| Rogue | can use bows, crossbows, guns and thrown | included, unchanged |
| Death Knight | cannot use daggers, staves or fist weapons | excluded, unchanged |

Rows not in this list (the common one-handed and two-handed axes, maces and swords, wands for
casters) were never in doubt and were not separately checked.

The relic permissions — `LIBRAM` Paladin, `IDOL` Druid, `SIGIL` Death Knight, `TOTEM` Shaman —
are not in doubt as a mapping. What still needs confirming is that those *key names* are what
`Modules/ItemInfo.lua` produces; that is the subclass-order check below.

### Confirming the subclass keys

The keys in `Data.WEAPONS` must match exactly what `Modules/ItemInfo.lua` produces from the
`GetAuctionItemSubClasses()` index map (spec 004 §4). They are **not** `GetItemInfo`'s strings,
which are localised.

Before checking any row above, confirm the key names themselves — a mismatch there disables a
whole category for every class at once, which is a much bigger failure than any single row and
looks identical to a data error.

## Tier tokens

`Data.TOKEN_IDS` is **intentionally empty**. Detection runs on the trailing word
(`…Vanquisher` / `…Protector` / `…Conqueror`), which covers every WotLK tier and any future one.

Add an id override **only** when a real token is observed being misclassified in game, and paste
the item link into the comment. Filling this table from memory would be strictly worse than
leaving it empty: a wrong id silently routes a token to the wrong classes, with no fallback
behind it, whereas a missing id just falls through to the name match.

The three class groupings are stable across all of WotLK and are not in doubt.

## If a weapon row turns out wrong later

1. Fix the row.
2. Add a fixture case to the `eligibility` suite (spec 009 §2) — CLAUDE.md's rule is a fixture
   per bug fixed in `Core/`, and this is the data `Core/` reads.
3. Add the line to the table above with the date.


## The subclass order — `Data/ItemClasses.lua` — verified

Checked in game on **2026-09-06** by Matt Lyon: `/rls itemclasses` on this client showed the
class list with weapons at position 1 and armour at position 2, and every row of the live
weapon and armour subclass lists matched `Data.WEAPON_SUBCLASSES` / `Data.ARMOR_SUBCLASSES`
semantically, including the `SHIELD` / `LIBRAM` / `IDOL` / `TOTEM` / `SIGIL` spellings.
`Data.SUBCLASS_ORDER_VERIFIED` is `true`.

`Data.WEAPON_SUBCLASSES` and `Data.ARMOR_SUBCLASSES` claim to be the order
`GetAuctionItemSubClasses(1)` and `GetAuctionItemSubClasses(2)` return on a 3.3.5a client.
Every armour and weapon permission in this addon is looked up through those positions, so an
order that is off by one sends every plate item to the leather rule.

**The check is one command in game:**

```
/rls itemclasses
```

It prints the live class list, then each live subclass beside our name for the same position.
Read down the two columns. When they agree, set `Data.SUBCLASS_ORDER_VERIFIED = true`.

Three things to look at while you are there:

1. **The class list.** `Data.CLASS_INDEX` claims weapons are position 1 and armour position 2.
   Both are read off the first list the command prints.
2. **The obsolete entries.** These tables are the *auction house* order, which drops the
   subclasses the item enum still carries — the armour "Buckler" and the two obsolete weapon
   slots. If a live list is longer than ours, that is why.
3. **The names in `Data.WEAPONS`.** `SHIELD`, `LIBRAM`, `IDOL`, `TOTEM` and `SIGIL` are armour
   subclasses here but weapon *permissions* in `Data/ClassArmor.lua`. The two spellings must
   match exactly.

### The recipe class position — NOT verified

`Data.CLASS_INDEX.RECIPE` is `9`, read off reference material for the 3.3.5a auction-house class
list and **never checked in game**. `Data.RECIPE_INDEX_VERIFIED` is `false`.

| Table | Claim | Status |
|---|---|---|
| `Data.CLASS_INDEX.WEAPON` | position 1 | verified 2026-09-06 |
| `Data.CLASS_INDEX.ARMOR` | position 2 | verified 2026-09-06 |
| `Data.CLASS_INDEX.RECIPE` | position 9 | **unverified — needs `/rls itemclasses` on a raid night** |

`/rls itemclasses` prints the live class list and names which position we expect recipes at, so
the check is reading one line. When it agrees, set `Data.RECIPE_INDEX_VERIFIED = true` here and
add the date.

The failure mode is bounded: the position is only used to mark an item a round candidate
(spec 004 §6). A wrong one auto-lists some other class of item — the host sees it in the setup
list and unticks it — and leaves recipes in the skipped list, where "Add item" puts them back.
No item is awarded wrongly and nobody is filtered off anything, because a recipe is `special`
either way.

### What happens while it is unverified

`Modules/ItemInfo.lua` compares the length of each live list against the length of our table at
load. On a mismatch it prints a warning and stops mapping subclasses at all: items then carry
no `armorSubclass` and no `weaponSubclass`, so checks 6 and 7 in `Core/Eligibility.lua` never
fire and **nobody is wrongly excluded**. Filtering is lost, not correctness.

A wrong order inside a list of the *right* length is the case that check cannot catch, and the
reason this page exists.
