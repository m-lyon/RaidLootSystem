# Verifying the data tables

`Data/ClassArmor.lua`, `Data/TierTokens.lua` and `Data/ItemClasses.lua` are the files
CLAUDE.md marks **verify, don't recall**. They were assembled from reference material and
**have not been checked against a live 3.3.5a server.**

Two flags stay `false` until someone works through this page and flips them:
`Data.WEAPONS_VERIFIED` and `Data.SUBCLASS_ORDER_VERIFIED`.

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

**Settled.** It is the mapping specified in spec 004 §5, reviewed and merged in PR #1, and it
encodes intent — *the armour class this class should be competing for at level 80* — rather than
what the client will physically let a character equip. A Hunter can wear leather; it should not
be taking leather off a Rogue.

The only thing worth re-checking is `Data.ARMOR_SLOTS`. It must contain the eight true armour
slots and **nothing else**. Cloaks, rings, necks and trinkets report an armour subclass but are
wearable by everyone, and including `INVTYPE_CLOAK` here would make every cloak in the game
cloth-only.

## The weapon table — check these first

Ordered by how likely I think they are to be wrong. Each is one in-game check: open the
character sheet of a character of that class, or inspect an item of that type and read the red
"cannot use" text.

| # | Check | Why it's doubtful |
|---|---|---|
| 1 | **Hunter — thrown.** Currently **excluded**. | Hunters use the ranged slot for bows/guns/crossbows. Whether thrown is also permitted is the entry I am least sure of. |
| 2 | **Paladin — polearm.** Currently **included**. | Reference material disagrees with itself here. If wrong, Paladins wrongly compete for polearms. |
| 3 | **Druid — polearm.** Currently **included**. | Believed correct (feral), but shares the doubt above. |
| 4 | **Shaman — polearm.** Currently **excluded**. | One search result claimed Shamans have polearms; a second source did not. Excluded on the balance of evidence. |
| 5 | **Warrior — staff, thrown, shield.** All **included**. | A wiki fetch during authoring returned Warriors as unable to use shields, which is certainly wrong — that source was lossy, so everything it touched is suspect. |
| 6 | **Priest / Mage / Warlock — dagger.** All **included**. | Same lossy source omitted these. Believed correct. |
| 7 | **Rogue — bow, crossbow, gun, thrown.** All **included**. | Same. |
| 8 | **Death Knight — no dagger, no fist, no staff.** | Believed correct; cheap to confirm. |
| 9 | **Relic subclasses** — `LIBRAM` Paladin, `IDOL` Druid, `SIGIL` Death Knight, `TOTEM` Shaman. | Mapping is confident; the *subclass key names* produced by `Modules/ItemInfo.lua` are what to confirm. |

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

## When you're done

1. Fix any wrong rows.
2. Set `Data.WEAPONS_VERIFIED = true`.
3. Add a fixture case to the `eligibility` suite (spec 009 §2) for every row you corrected —
   CLAUDE.md's rule is a fixture per bug fixed in `Core/`, and this is the data `Core/` reads.
4. Delete the doubt table above and replace it with the date and server build verified against.


## The subclass order — `Data/ItemClasses.lua`

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

### What happens while it is unverified

`Modules/ItemInfo.lua` compares the length of each live list against the length of our table at
load. On a mismatch it prints a warning and stops mapping subclasses at all: items then carry
no `armorSubclass` and no `weaponSubclass`, so checks 6 and 7 in `Core/Eligibility.lua` never
fire and **nobody is wrongly excluded**. Filtering is lost, not correctness.

A wrong order inside a list of the *right* length is the case that check cannot catch, and the
reason this page exists.
