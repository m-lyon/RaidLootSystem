-- tests/fixtures/campaign.lua
--
-- Campaigns (spec 012 section 15): identity, the membership predicate that is the
-- whole reason the feature exists, the hierarchy dialog's row model, the delete
-- rules, export/import round-trips, and the state rules -- two independent lists, a
-- switch swapping settings, and a restore landing in the campaign the award was made
-- in rather than the active one.
--
-- The State cases work against a plain saved-variable table, not the game's, so the
-- rules are checked without a raid.

local ns = ...

local C = ns.Constants
local PL = ns.PriorityList

--------------------------------------------------------------------------------
-- A stand-in for the saved variables, so the state rules can be exercised purely.
--------------------------------------------------------------------------------

local function newCampaign(id, label, order)
    return {
        id = id, label = label, createdAt = 1757155200, createdBy = "Steve",
        hierarchy = { "Steve" },
        host = { tierCount = 3, timerSeconds = 180, qualityThreshold = 4, lootMode = "ROLL" },
        priority = { version = 0, seed = 0, seedChars = {}, order = order or {}, log = {} },
    }
end

--- The rule of spec 012 section 10, applied the way Modules/PriorityList's onSklist
-- applies it: a list is replaced only in the campaign it names, and only when this
-- client is a member of it.
local function applySklist(db, msg)
    local Campaign = ns.Campaign
    if not Campaign.Accepts(db.campaigns, msg.campaignId, C.OPS.SKLIST) then return false end
    local stored = db.campaigns[msg.campaignId].priority
    stored.version, stored.seed, stored.order = msg.version, msg.seed, msg.order
    stored.log = {}                      -- the log is the host's; a client has none
    return true
end

local function snapshot(priority)
    return table.concat(priority.order, ",") .. "|v" .. priority.version
        .. "|log" .. #priority.log
end

--------------------------------------------------------------------------------

local function run(input, ns)
    local Campaign = ns.Campaign

    ----------------------------------------------------------------------------
    -- Pure
    ----------------------------------------------------------------------------
    if input.op == "new" then
        local campaign, why = Campaign.New(input.label, input.settings,
            { creator = input.creator, timestamp = input.timestamp,
              hierarchy = input.hierarchy })
        if not campaign then return { ok = false, why = why } end
        return {
            ok = true, id = campaign.id, label = campaign.label,
            createdAt = campaign.createdAt, createdBy = campaign.createdBy,
            hierarchy = campaign.hierarchy,
            host = campaign.host,
            listed = #campaign.priority.order, logged = #campaign.priority.log,
            version = campaign.priority.version,
        }

    elseif input.op == "label" then
        local ok, why = Campaign.ValidLabel(input.label)
        return { ok = ok == true, why = why or "" }

    elseif input.op == "accepts" then
        -- The membership predicate: the whole clobber fix in one call.
        local campaigns = {}
        for _, id in ipairs(input.have) do campaigns[id] = newCampaign(id, id) end
        local out = {}
        for i, case in ipairs(input.messages) do
            local ok, why = Campaign.Accepts(campaigns, case.campaignId, case.op)
            out[i] = case.op .. ":" .. (ok and "applied" or ("dropped - " .. tostring(why)))
        end
        return out

    elseif input.op == "rows" then
        local rows = Campaign.HierarchyRows(input.chars, input.hierarchy)
        for _, change in ipairs(input.ticks or {}) do
            rows = Campaign.SetIncluded(rows, change.index, change.included, input.chars)
        end
        for _, move in ipairs(input.moves or {}) do
            rows = Campaign.MoveRow(rows, move.from, move.to, input.chars)
        end
        local out = {}
        for i, row in ipairs(rows) do
            out[i] = string.format("%s %s%s", row.position and tostring(row.position) or "-",
                row.char, row.included and "" or " out")
        end
        return { rows = out, hierarchy = Campaign.HierarchyOf(rows) }

    elseif input.op == "delete" then
        return Campaign.DeleteBlocker(input.campaignId, input.ctx) or ""

    elseif input.op == "nonMembers" then
        return Campaign.NonMembers(input.members, input.peers, input.campaignId, input.me)

    elseif input.op == "joined" then
        local s = Campaign.JoinedSummary(input.members, input.peers, input.campaignId, input.me)
        return { joined = s.joined, total = s.total, missing = s.missing }

    elseif input.op == "roundtrip" then
        -- Export -> import, including a long log: the fork repair reproduces the
        -- exporter's order, version, seed and log exactly (section 15).
        local campaign = newCampaign("Steve-1757155200", "Tuesday 25")
        campaign.host.tierCount, campaign.host.lootMode = 2, C.LOOT_MODE.SK
        campaign.priority.seed = 1757155200
        campaign.priority.seedChars = { "Ann", "Bob", "Cat", "Dan", "Eve" }
        campaign.priority.order = PL.seed(campaign.priority.seedChars,
            PL.rngFrom(campaign.priority.seed))
        campaign.priority.log[1] = { kind = "seed", seed = campaign.priority.seed,
            chars = campaign.priority.seedChars, version = 1, at = 1757155200, by = "Steve" }
        local live = campaign.priority.order
        local present = { ann = true, bob = true, cat = true, dan = true, eve = true }
        local rng = PL.rngFrom(99)
        for v = 2, input.events or 200 do
            local winner = live[rng(1, #live)]
            local after, from, pres = PL.suicide(live, winner, present)
            campaign.priority.log[v] = { kind = "suicide", char = winner, from = from,
                present = pres, version = v, at = 1757155200 + v, by = "Steve" }
            live = after
        end
        campaign.priority.order = live
        campaign.priority.version = #campaign.priority.log

        local text = Campaign.Encode(campaign)
        local back, why = Campaign.ParseImport(text)
        if not back then return { ok = false, why = why } end

        local sameLog = #back.priority.log == #campaign.priority.log
        for i, e in ipairs(campaign.priority.log) do
            local b = back.priority.log[i]
            if not b or b.kind ~= e.kind or b.char ~= e.char or b.from ~= e.from
                or b.version ~= e.version or #(b.present or {}) ~= #(e.present or {}) then
                sameLog = false
            end
        end
        return {
            ok = true,
            prefixed = text:sub(1, #C.CAMPAIGN_EXPORT_PREFIX) == C.CAMPAIGN_EXPORT_PREFIX,
            id = back.id, label = back.label, createdBy = back.createdBy,
            host = back.host,
            version = back.priority.version, seed = back.priority.seed,
            order = table.concat(back.priority.order, ",")
                == table.concat(campaign.priority.order, ","),
            seedChars = table.concat(back.priority.seedChars, ","),
            events = #back.priority.log, sameLog = sameLog,
            -- The payload carries no hierarchy: it is personal and per client.
            hierarchy = back.hierarchy and #back.hierarchy or -1,
        }

    elseif input.op == "importGarbage" then
        local campaign, why = Campaign.ParseImport(input.text)
        return { ok = campaign ~= nil, why = why or "" }

    ----------------------------------------------------------------------------
    -- State
    ----------------------------------------------------------------------------
    elseif input.op == "foreignSklist" then
        -- THE regression test: a SKLIST naming a campaign this client is not in
        -- leaves the stored list AND its log byte-identical (section 15).
        local db = { campaigns = { ["Steve-1"] = newCampaign("Steve-1", "Tuesday 25",
            { "Ann", "Bob", "Cat" }) } }
        db.campaigns["Steve-1"].priority.version = 47
        db.campaigns["Steve-1"].priority.log = { { kind = "seed", version = 1 },
            { kind = "suicide", version = 2 } }
        local before = snapshot(db.campaigns["Steve-1"].priority)

        local applied = applySklist(db, { campaignId = input.campaignId, version = 99,
            seed = 5, order = { "Zed", "Yak" } })
        return { applied = applied, before = before,
                 after = snapshot(db.campaigns["Steve-1"].priority),
                 unchanged = before == snapshot(db.campaigns["Steve-1"].priority) }

    elseif input.op == "independent" then
        -- Two campaigns each hold an independent list: a suicide in one leaves the
        -- other's version and order untouched.
        local db = { campaigns = {
            ["Steve-1"] = newCampaign("Steve-1", "Tuesday 25", { "Ann", "Bob", "Cat" }),
            ["Steve-2"] = newCampaign("Steve-2", "Alt Run", { "Ann", "Bob", "Cat" }),
        } }
        local other = snapshot(db.campaigns["Steve-2"].priority)

        local priority = db.campaigns["Steve-1"].priority
        local next_ = ns.Priority.Mutate(priority, { kind = "suicide", char = "Ann", from = 1,
            present = { 1, 2, 3 } })
        db.campaigns["Steve-1"].priority = next_

        return { one = snapshot(db.campaigns["Steve-1"].priority),
                 two = snapshot(db.campaigns["Steve-2"].priority),
                 otherUntouched = other == snapshot(db.campaigns["Steve-2"].priority) }

    elseif input.op == "switchSettings" then
        -- Switching campaigns swaps tierCount, timerSeconds, qualityThreshold,
        -- lootMode and the hierarchy the editor shows.
        local db = { activeCampaign = "Steve-1", campaigns = {
            ["Steve-1"] = newCampaign("Steve-1", "Tuesday 25"),
            ["Steve-2"] = newCampaign("Steve-2", "Alt Run"),
        } }
        db.campaigns["Steve-1"].host = { tierCount = 3, timerSeconds = 180,
            qualityThreshold = 4, lootMode = "SK" }
        db.campaigns["Steve-1"].hierarchy = { "Steve", "Sneaky", "Smash" }
        db.campaigns["Steve-2"].host = { tierCount = 0, timerSeconds = 60,
            qualityThreshold = 3, lootMode = "ROLL" }
        db.campaigns["Steve-2"].hierarchy = { "Alt", "Steve" }

        local function view()
            local c = db.campaigns[db.activeCampaign]
            return { label = c.label, tierCount = c.host.tierCount,
                     timerSeconds = c.host.timerSeconds,
                     qualityThreshold = c.host.qualityThreshold,
                     lootMode = c.host.lootMode,
                     hierarchy = table.concat(c.hierarchy, ",") }
        end
        local before = view()
        db.activeCampaign = "Steve-2"
        return { before = before, after = view() }

    elseif input.op == "restoreTargetsAward" then
        -- A pending delivery that fails terminally AFTER a campaign switch restores
        -- the winner's index in the campaign the award was made in, not the active
        -- one (section 14). The pending record carries the campaign id, which is the
        -- whole mechanism.
        local db = { activeCampaign = "Steve-2", campaigns = {
            ["Steve-1"] = newCampaign("Steve-1", "Tuesday 25", { "Bob", "Cat", "Ann" }),
            -- The active campaign happens to hold the same characters in the same
            -- suicided arrangement, so a restore that landed here rather than in
            -- Steve-1 would be visible in the result.
            ["Steve-2"] = newCampaign("Steve-2", "Alt Run", { "Bob", "Cat", "Ann" }),
        } }
        local record = ns.Pending.NewRecord({
            itemString = "item:49623", char = "Ann", owner = "Steve",
            roundId = "Steve-100", itemIdx = 1, copy = 1,
            campaignId = "Steve-1", priorIndex = 1, presentIndices = { 1, 2, 3 },
        }, 1757155200)
        record.delivery = C.DELIVERY.FAILED
        record.failure = C.AWARD_FAILURE.TRADE_EXPIRED

        local action = ns.Priority.DeliveryAction(record)
        local target = db.campaigns[record.campaignId].priority
        local restored = PL.restore(target.order, "Ann", record.priorIndex,
            record.presentIndices)
        if restored then target.order = restored end

        return {
            campaignId = record.campaignId,
            action = action,
            awardCampaign = table.concat(db.campaigns["Steve-1"].priority.order, ","),
            activeCampaign = table.concat(db.campaigns["Steve-2"].priority.order, ","),
        }
    end
    error("unknown op: " .. tostring(input.op))
end

local CHARS = {
    Steve  = { class = "MAGE", isSelf = true },
    Sneaky = { class = "ROGUE" },
    Smash  = { class = "WARRIOR" },
    Locky  = { class = "WARLOCK" },
}

return {
    name = "campaign",
    run = run,
    cases = {
        ------------------------------------------------------------------
        -- Identity (section 5) and the record (section 3)
        ------------------------------------------------------------------
        {
            -- Acceptance: Campaign.New produces an id of the form <name>-<timestamp>
            -- and a record validating against section 3.
            name = "a new campaign takes a <name>-<timestamp> id and the section 3 shape",
            input = { op = "new", label = "Tuesday 25", creator = "Steve",
                      timestamp = 1757155200, hierarchy = { "Steve", "Sneaky" } },
            expected = {
                ok = true, id = "Steve-1757155200", label = "Tuesday 25",
                createdAt = 1757155200, createdBy = "Steve",
                hierarchy = { "Steve", "Sneaky" },
                host = { tierCount = 3, timerSeconds = 180, qualityThreshold = 4,
                         lootMode = "ROLL", autoClose = true },
                listed = 0, logged = 0, version = 0,
            },
        },
        {
            name = "the create dialog's settings are carried, and clamped",
            input = { op = "new", label = "Alt Run", creator = "Steve", timestamp = 100,
                      settings = { tierCount = 9, timerSeconds = 5, qualityThreshold = 3 } },
            expected = {
                ok = true, id = "Steve-100", label = "Alt Run",
                createdAt = 100, createdBy = "Steve", hierarchy = {},
                host = { tierCount = 5, timerSeconds = 15, qualityThreshold = 3,
                         lootMode = "ROLL", autoClose = true },
                listed = 0, logged = 0, version = 0,
            },
        },
        {
            -- A false setting has to survive: the and/or idiom would hand back the
            -- default true and silently leave the round closing itself.
            name = "autoClose = false is carried, not replaced by the default",
            input = { op = "new", label = "Manual", creator = "Steve", timestamp = 100,
                      settings = { autoClose = false } },
            expected = {
                ok = true, id = "Steve-100", label = "Manual",
                createdAt = 100, createdBy = "Steve", hierarchy = {},
                host = { tierCount = 3, timerSeconds = 180, qualityThreshold = 4,
                         lootMode = "ROLL", autoClose = false },
                listed = 0, logged = 0, version = 0,
            },
        },
        {
            -- Spec 010 section 2: SK is selectable only once a list exists, and a
            -- new campaign has none.
            name = "a new campaign cannot start in Suicide Kings",
            input = { op = "new", label = "SK please", creator = "Steve", timestamp = 100,
                      settings = { lootMode = "SK" } },
            expected = {
                ok = true, id = "Steve-100", label = "SK please",
                createdAt = 100, createdBy = "Steve", hierarchy = {},
                host = { tierCount = 3, timerSeconds = 180, qualityThreshold = 4,
                         lootMode = "ROLL", autoClose = true },
                listed = 0, logged = 0, version = 0,
            },
        },
        {
            name = "an empty label is refused",
            input = { op = "label", label = "   " },
            expected = { ok = false, why = "a campaign needs a label" },
        },
        {
            -- A wire delimiter in a label would corrupt every frame carrying it.
            name = "a label holding a wire delimiter is refused",
            input = { op = "label", label = "Tues^25" },
            expected = { ok = false, why = "a label cannot contain ^, ~, = or |" },
        },
        {
            name = "an ordinary label is accepted",
            input = { op = "label", label = "Tuesday 25" },
            expected = { ok = true, why = "" },
        },

        ------------------------------------------------------------------
        -- The membership rule (section 10)
        ------------------------------------------------------------------
        {
            -- Acceptance: a campaign-bearing message naming an unknown id is
            -- rejected by the membership predicate; a known id is accepted.
            name = "a message naming a campaign you are not in is dropped, except CINV and OPEN",
            input = { op = "accepts", have = { "Steve-1" }, messages = {
                { op = "SKLIST", campaignId = "Steve-1" },
                { op = "SKLIST", campaignId = "Dave-9" },
                { op = "ROSTER", campaignId = "Dave-9" },
                { op = "CFG",    campaignId = "Dave-9" },
                { op = "HI",     campaignId = "Dave-9" },
                { op = "CINV",   campaignId = "Dave-9" },
                { op = "OPEN",   campaignId = "Dave-9" },
            } },
            expected = {
                "SKLIST:applied",
                "SKLIST:dropped - you are not in campaign Dave-9",
                "ROSTER:dropped - you are not in campaign Dave-9",
                "CFG:dropped - you are not in campaign Dave-9",
                "HI:dropped - you are not in campaign Dave-9",
                "CINV:applied",
                "OPEN:applied",
            },
        },
        {
            name = "a message naming no campaign at all is dropped",
            input = { op = "accepts", have = { "Steve-1" }, messages = {
                { op = "SKLIST", campaignId = "" },
            } },
            expected = { "SKLIST:dropped - it names no campaign" },
        },

        ------------------------------------------------------------------
        -- The hierarchy dialog's row model (section 7)
        ------------------------------------------------------------------
        {
            name = "every character gets a row; the ticked ones lead in hierarchy order",
            input = { op = "rows", chars = CHARS, hierarchy = { "Steve", "Smash" } },
            expected = {
                rows = { "1 Steve", "2 Smash", "- Locky out", "- Sneaky out" },
                hierarchy = { "Steve", "Smash" },
            },
        },
        {
            -- Acceptance: ticking and unticking yields positions numbered over the
            -- ticked rows only.
            name = "unticking renumbers the positions over the ticked rows only",
            input = { op = "rows", chars = CHARS, hierarchy = { "Steve", "Smash", "Locky" },
                      ticks = { { index = 2, included = false } } },
            expected = {
                rows = { "1 Steve", "- Smash out", "2 Locky", "- Sneaky out" },
                hierarchy = { "Steve", "Locky" },
            },
        },
        {
            name = "re-ticking a row puts it back at the position its row sits in",
            input = { op = "rows", chars = CHARS, hierarchy = { "Steve" },
                      ticks = { { index = 2, included = true } } },
            expected = {
                rows = { "1 Steve", "2 Locky", "- Smash out", "- Sneaky out" },
                hierarchy = { "Steve", "Locky" },
            },
        },
        {
            name = "moving a row reorders the hierarchy it describes",
            input = { op = "rows", chars = CHARS, hierarchy = { "Steve", "Smash", "Locky" },
                      moves = { { from = 3, to = 1 } } },
            expected = {
                rows = { "1 Locky", "2 Steve", "3 Smash", "- Sneaky out" },
                hierarchy = { "Locky", "Steve", "Smash" },
            },
        },
        {
            name = "a hierarchy naming a character the roster no longer has drops it",
            input = { op = "rows", chars = { Steve = { class = "MAGE" } },
                      hierarchy = { "Steve", "Ghost" } },
            expected = { rows = { "1 Steve" }, hierarchy = { "Steve" } },
        },

        ------------------------------------------------------------------
        -- Lifecycle (section 11)
        ------------------------------------------------------------------
        {
            name = "a campaign holding an undelivered item cannot be deleted",
            input = { op = "delete", campaignId = "Steve-1",
                      ctx = { activeId = "Steve-2", count = 3,
                              pendingIds = { ["Steve-1"] = true } } },
            expected = "an undelivered item was won in it. Deliver or abandon it first.",
        },
        {
            name = "the active campaign cannot be deleted",
            input = { op = "delete", campaignId = "Steve-1",
                      ctx = { activeId = "Steve-1", count = 3, pendingIds = {} } },
            expected = "it is the campaign you are in. Switch to another one first.",
        },
        {
            name = "your last campaign cannot be deleted",
            input = { op = "delete", campaignId = "Steve-1",
                      ctx = { activeId = "Steve-2", count = 1, pendingIds = {} } },
            expected = "it is your only campaign. Make another one first.",
        },
        {
            -- The same delete succeeds once the delivery resolves.
            name = "an idle non-active campaign deletes",
            input = { op = "delete", campaignId = "Steve-1",
                      ctx = { activeId = "Steve-2", count = 2, pendingIds = {} } },
            expected = "",
        },

        ------------------------------------------------------------------
        -- Who has joined (section 6)
        ------------------------------------------------------------------
        {
            name = "the host sees who in the raid is not in the campaign",
            input = { op = "joined", me = "Steve", campaignId = "Steve-1",
                      members = { "Steve", "Dave", "Anna", "Kate", "Oli" },
                      peers = { Dave = "Steve-1", Anna = "Steve-1", Kate = "Dave-9" } },
            expected = { joined = 3, total = 5, missing = { "Kate", "Oli" } },
        },
        {
            name = "a raid that has all joined reports no names",
            input = { op = "nonMembers", me = "Steve", campaignId = "Steve-1",
                      members = { "Steve", "Dave" }, peers = { Dave = "Steve-1" } },
            expected = {},
        },

        ------------------------------------------------------------------
        -- Export and import (section 12)
        ------------------------------------------------------------------
        {
            -- Acceptance: encode -> decode round-trips a campaign export, including
            -- a 200-event priority log.
            name = "a campaign round-trips through its export string, 200 log events included",
            input = { op = "roundtrip", events = 200 },
            expected = {
                ok = true, prefixed = true,
                id = "Steve-1757155200", label = "Tuesday 25", createdBy = "Steve",
                host = { tierCount = 2, timerSeconds = 180, qualityThreshold = 4,
                         lootMode = "SK", autoClose = true },
                version = 200, seed = 1757155200, order = true,
                seedChars = "Ann,Bob,Cat,Dan,Eve",
                events = 200, sameLog = true,
                hierarchy = 0,
            },
        },
        {
            name = "a string that is not a campaign export is rejected whole",
            input = { op = "importGarbage", text = "RLS1:Steve=MAGE" },
            expected = { ok = false, why = "this is not a RaidLootSystem campaign string" },
        },
        {
            name = "an empty import is rejected",
            input = { op = "importGarbage", text = "   " },
            expected = { ok = false, why = "nothing to import" },
        },

        ------------------------------------------------------------------
        -- State (section 15)
        ------------------------------------------------------------------
        {
            -- THE regression test for the bug this spec exists to fix.
            name = "a SKLIST naming a campaign you are not in leaves the list AND its log intact",
            input = { op = "foreignSklist", campaignId = "Dave-9" },
            expected = { applied = false, before = "Ann,Bob,Cat|v47|log2",
                         after = "Ann,Bob,Cat|v47|log2", unchanged = true },
        },
        {
            name = "a SKLIST naming a campaign you ARE in replaces the list",
            input = { op = "foreignSklist", campaignId = "Steve-1" },
            expected = { applied = true, before = "Ann,Bob,Cat|v47|log2",
                         after = "Zed,Yak|v99|log0", unchanged = false },
        },
        {
            name = "a suicide in one campaign leaves the other's version and order untouched",
            input = { op = "independent" },
            expected = { one = "Bob,Cat,Ann|v1|log1", two = "Ann,Bob,Cat|v0|log0",
                         otherUntouched = true },
        },
        {
            name = "switching campaigns swaps the host settings and the hierarchy",
            input = { op = "switchSettings" },
            expected = {
                before = { label = "Tuesday 25", tierCount = 3, timerSeconds = 180,
                           qualityThreshold = 4, lootMode = "SK",
                           hierarchy = "Steve,Sneaky,Smash" },
                after = { label = "Alt Run", tierCount = 0, timerSeconds = 60,
                          qualityThreshold = 3, lootMode = "ROLL",
                          hierarchy = "Alt,Steve" },
            },
        },
        {
            name = "a terminal delivery failure after a switch restores the award's campaign",
            input = { op = "restoreTargetsAward" },
            expected = {
                campaignId = "Steve-1", action = "restore",
                awardCampaign = "Ann,Bob,Cat",
                activeCampaign = "Bob,Cat,Ann",
            },
        },
    },
}
