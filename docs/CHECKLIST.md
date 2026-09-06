# What is left to verify by hand

Everything in the tree is built and fixture-tested (`lua tests/run.lua`, `tests/purity.sh`,
CI on `main`). What follows needs a 3.3.5a client, and for most of it a second client and the
mod-playerbots server. Work top to bottom: the early sections make the later ones trustworthy.

Tick a box when done. Where a check needs a code change afterwards, it says so.

---

## 1. Install and load

- [ ] Copy the addon to `Interface/AddOns/RaidLootSystem` on each client. Log in. No Lua errors
      on load (`/console scriptErrors 1` to be sure).
- [ ] `/rls status` prints the version, roster size and master looter.
- [ ] `/rls` opens the hierarchy editor. Claim your character and your bots, drag them into order.
- [ ] `/reload`. The roster and order survive.

## 2. Data tables (`Data/VERIFY.md` has the detail)

### Item class order — `SUBCLASS_ORDER_VERIFIED`

- [ ] `/rls itemclasses`. Read the live weapon and armour subclass lists beside the addon's. Every
      row must match by position. The last line says whether the mapping is in use.
- [ ] If they match: set `Data.SUBCLASS_ORDER_VERIFIED = true` in `Data/ItemClasses.lua`.
- [ ] If the lengths differ, filtering is off for the session and the addon says so; fix the
      table order to the live one and re-check.

### Weapon permissions — `WEAPONS_VERIFIED`

Done. The facts from `notes.md` are in `Data/VERIFY.md`, the Hunter thrown row is fixed, the flag
is `true`, and the `eligibility` suite pins every confirmed line. Nothing left here unless a raid
night contradicts one of them.

- [ ] Row 9 of the old doubt list, the relic key spellings `LIBRAM` / `IDOL` / `SIGIL` / `TOTEM`,
      is confirmed by `/rls itemclasses` above, not by a class check.

### Tier tokens

- [ ] Loot or link a real tier token (Naxx "…of the Lost Conqueror/Protector/Vanquisher", Ulduar
      "…of the Wayward…", ToC "Trophy…", ICC "…Mark of Sanctification"). `/rls roll <link>` then
      open the roll window: only the token's classes are enterable.
- [ ] ICC marks end in "Sanctification", not the class-set word. If they are not recognised, add
      their ids to `Data.TOKEN_IDS` with the link in a comment (CLAUDE.md: never a fabricated id).

## 3. Constants that need the server build

- [ ] **Bot equip command.** Win an item on one of your bots, let the addon deliver it, and watch
      the whisper. `C.BOT_EQUIP_COMMAND` sends `equip <item link>`. If the bot rejects the link
      form, change it to the name form; if `equip` is not the verb, change the verb. Note the
      answer in spec 007 §7.
- [ ] **Bot trade acceptance.** Take an item into your bags (shift-click Award), then Deliver to
      a bot within 11 yards. If the bot accepts the trade on its own, leave
      `Pending.BOT_TRADE_COMMAND = nil`. If it needs a whisper, set the command there.
- [ ] Auto-equip fires exactly once per successful bot delivery, never for a real player, never
      for another player's bot, never on a failure, and not at all with `autoEquipWinners` off.

## 4. The pipeline, solo (`/rls simulate`)

No raid needed. Each run prints `[sim]` lines and ends with "done".

- [ ] `/rls simulate` — the roll window opens, fake players submit and one revises, the batch
      closes, results render, "done" prints. No chat line reached a real channel and no addon
      message was sent (nobody else is there to receive one; the chat log shows only `[sim]`).
- [ ] `/rls simulate scenario=tie` — a visible `50 -> 30 / 50 -> 80 (tie re-roll)` in results.
- [ ] `scenario=duplicate` — two winners on item 1, T1 then T2.
- [ ] `scenario=unclaimed` — item 2 reads "No entries — master looter's choice".
- [ ] `scenario=contested` — the host panel's roster health lists Bonk contested by Simdave and
      Simanna; neither entry for Bonk is accepted.
- [ ] `scenario=token`, `scenario=special`, `scenario=abort` (ends with "aborted: ML_CHANGED"),
      `scenario=chunked` (summary says how many chunks OPEN needed).
- [ ] `scenario=sk`, `scenario=star`, `scenario=absent`, `scenario=restore`. After each, `/rls sk
      list`: your real priority list is unchanged (version and order), because the simulation
      worked on a copy.
- [ ] `/rls history`: the simulated batches are hidden until "Show simulated" is ticked.
- [ ] `/rls simulate stop` mid-run restores everything; a following `/rls simulate` works.

## 5. Two real clients, one master looter

Set the group to master loot with you as master looter. The other client is "the client" below.

### Roster and hierarchy (spec 001)

- [ ] Both clients see each other's rosters within a few seconds (`/rls status`, host panel roster
      health). `/rls request` forces a resend.
- [ ] Claim the same character on both clients: it shows as contested on both, and cannot be
      entered by either. Remove it on one: the contest clears.
- [ ] A raid member without the addon shows "not running" in the host panel's addon status.

### Host panel (spec 006)

- [ ] `/rls host` on the client is refused; on the host it opens. Hand master looter over: the
      panel closes on you and opens for them.
- [ ] Change the tier count with the slider: one raid-chat line, one CFG, and the client's
      hierarchy editor shows the new count without a reload. Same for the timer.
- [ ] Open a corpse as master looter: candidates list with icons; skipped items counted; Add item
      by pasted link, by shift-clicked link, and by dragging a bag item onto the box.
- [ ] Start roll is disabled with a reason when not on master loot, when nothing is ticked, and
      while a batch is open.
- [ ] Verbosity Off: a whole batch produces no chat. Verbose: a 6-item batch with ~20 entries
      drains without a "throttled" message.

### Roll window (spec 005)

- [ ] A 6-item batch with a 9-character roster fits without scrolling at default UI scale. A
      7th item adds the horizontal slider.
- [ ] A plate item greys every cloth/leather/mail row with a class-specific tooltip. Right-click
      enables it with the orange marker; right-click on a "not in the raid" cell does nothing.
- [ ] The client submits: the host's detail panel updates within half a second. Revising shows
      "unsent changes" until re-submitted. Pass all counts the client as in with zero entries.
- [ ] Close the window mid-batch: the minimap button pulses until you submit. `/rls` reopens it
      with the ticks intact.
- [ ] `/reload` mid-batch on the client: the grid, countdown and unsubmitted ticks come back.
- [ ] Results: not-consulted entries shown greyed as "T3 — not consulted", not as losses.
- [ ] Abort from the host panel: the client's window shows the reason for ten seconds, then closes.

### Award and delivery (spec 007)

- [ ] Award from the corpse to a bot in range: the slot clears, the results row reads
      "delivered", the bot gets the equip whisper.
- [ ] Award to a winner 200 yards away: "out of range" with Retry; retry after they close the
      distance succeeds.
- [ ] Award with the winner's bags full: "Award didn't complete — check X's bags", not a silent
      success.
- [ ] A duplicate drop: both copies awarded to two characters, each from its own slot.
- [ ] Shift-click Award: the item lands in your bags, the pending record shows a 2-hour countdown
      in the host panel and in `/rls pending`. Log out and in: the login reminder names item,
      recipient and time left. Deliver by trade: the record closes, history updates in place.
- [ ] Let one expire (or `/rls abandon <n>`): it stays listed as expired, and the results row
      offers no Retry.
- [ ] Hand master looter away while holding a pending item: `/rls pending` and `/rls deliver <n>`
      still work without the panel.

### History (spec 008)

- [ ] After a batch, `/rls history` on both clients shows one record each; the host's lacks the
      "(client)" badge and shows delivery state, the client's does not.
- [ ] Export CSV of a 6-item batch with 20 entries: 20 rows plus the header.
- [ ] Character summary for a bot lists only what it was awarded.

### Suicide Kings (spec 010)

- [ ] Seed from the host panel: announced, versioned, and every client shows the identical order
      and version (`/rls sk list` on each). Loot mode becomes selectable.
- [ ] Switch to Suicide Kings, run a batch: no rolls, positions shown in the window, the winner
      drops to the bottom on every client after RESULT. `/reload` every client; all copies agree.
- [ ] Two of your bots at home during a batch: their positions do not move.
- [ ] Fail a delivery terminally (abandon it): the winner is restored to its prior index on every
      client, version bumped, announced. `/rls sk verify` on the host reports a match.
- [ ] Manual move / Bottom / Top from the panel: each confirmed, announced, logged; `verify` still
      matches afterwards.

### Failure modes (spec 009 §5)

- [ ] Master looter handed over mid-batch: both clients abort with "the master looter changed".
- [ ] `/reload` mid-batch on the **host**: clients time out a minute after the deadline and abort
      cleanly as "the host left the raid".
- [ ] A corpse despawning mid-batch aborts as "the loot is no longer there".

## 6. When it has survived a raid night

- [ ] Tag `0.1.0` (the `.toc` version). Stay on `0.x` until then.
- [ ] `notes.md` has been folded into `Data/VERIFY.md`; delete it when you are happy with that.
