-- Modules/Simulate.lua
--
-- `/rls simulate` (spec 009 section 4): the whole pipeline, run solo inside the game.
-- A loopback transport stands in for SendAddonMessage, fake players publish rosters
-- and submit entries, and the real host code (Session, Resolve, Award records,
-- History) and the real local mirror (Client, the roll window) execute unchanged.
-- Only the wire, the chat, the group and the award click are faked.
--
-- Everything above the "WoW-facing" divider is pure and fixture-tested by the
-- `simulate` suite: the scenarios, the players and items they build, and the entries
-- each fake player submits.
--
-- Guard rails (section 4): refused while a real batch is open; never a real addon
-- message, chat line or whisper; history records tagged `simulated`; the priority
-- list is a copy that is discarded; GiveMasterLoot is never called.

local ADDON, ns = ...

ns.Simulate = {}
local Simulate = ns.Simulate

local C = ns.Constants

--------------------------------------------------------------------------------
-- Pure: fake players and fake items
--------------------------------------------------------------------------------

-- Fake players and their rosters. Classes cover cloth, leather, mail and plate so
-- the eligibility filter has something to do.
local PLAYERS = {
    { name = "Simdave", chars = { { "Simdave", "PRIEST" }, { "Bonk", "WARRIOR" },
                                  { "Chop", "DEATHKNIGHT" }, { "Grubby", "SHAMAN" },
                                  { "Wisp", "MAGE" } } },
    { name = "Simanna", chars = { { "Simanna", "DRUID" }, { "Stabby", "ROGUE" },
                                  { "Holy", "PALADIN" }, { "Shooty", "HUNTER" },
                                  { "Dotty", "WARLOCK" } } },
    { name = "Simerin", chars = { { "Simerin", "WARRIOR" }, { "Sparkle", "MAGE" },
                                  { "Bear", "DRUID" }, { "Boomer", "SHAMAN" },
                                  { "Slice", "ROGUE" } } },
    { name = "Simkate", chars = { { "Simkate", "HUNTER" }, { "Pally", "PALADIN" },
                                  { "Shadow", "PRIEST" }, { "Frost", "DEATHKNIGHT" },
                                  { "Fel", "WARLOCK" } } },
    { name = "Simoli",  chars = { { "Simoli", "ROGUE" }, { "Tank", "WARRIOR" },
                                  { "Heals", "PRIEST" }, { "Zap", "MAGE" },
                                  { "Totem", "SHAMAN" } } },
}

-- Fake drops. Real 3.3.5a ids where the name matters (the token is classified by its
-- trailing word, cached or not); the rest resolve from the client's cache if they
-- can and enter as `special` if they cannot, which is itself a path worth walking.
local ITEMS = {
    { id = 50362, name = "Deathbringer's Will" },
    { id = 49623, name = "Shadowmourne" },
    { id = 50006, name = "Corpse-Impaling Spike" },
    { id = 50034, name = "Zod's Repeating Longbow" },
    { id = 50035, name = "Black Bruise" },
    { id = 50008, name = "Ring of Rapid Ascent" },
    { id = 50401, name = "Ashen Band of Endless Vengeance" },
    { id = 50429, name = "Rowan's Rifle of Silver Bullets" },
    { id = 50415, name = "Bryntroll, the Bone Arbiter" },
    { id = 50040, name = "Juggernaut Band" },
    { id = 50644, name = "Ring of Maddening Whispers" },
    { id = 50021, name = "Loop of the Endless Labyrinth" },
}
local TOKEN = { id = 40631, name = "Helm of the Lost Conqueror" }   -- by trailing word
local SPECIAL = { id = 49426, name = "Emblem of Frost" }

--- A link the item-info reader accepts, carrying the name so classification by
-- name works on a cold cache.
function Simulate.FakeLink(id, name)
    return string.format("|cffa335ee|Hitem:%d:0:0:0:0:0:0:0:80|h[%s]|h|r", id, name)
end

Simulate.SCENARIOS = {
    default   = "3 fake players, 4 characters each, 4 items",
    tie       = "a boundary tie forcing a visible re-roll",
    duplicate = "two copies spilling from T1 into T2",
    unclaimed = "an item nobody enters",
    contested = "two players claiming the same character",
    token     = "a tier token and its class filtering",
    special   = "an unclassifiable item with the filter off",
    abort     = "the master looter changing mid-batch",
    chunked   = "a payload large enough to need multi-chunk transport",
    sk        = "a seeded priority list deciding a batch with no rolls",
    star      = "a character that would win two items taking its starred one",
    absent    = "a suicide with absent characters holding their indices",
    restore   = "a failed delivery returning a character to its prior index",
}

--- Parse "items=6 players=5 scenario=tie".
function Simulate.ParseArgs(text)
    local args = {}
    for key, value in (text or ""):gmatch("(%w+)=(%S+)") do args[key] = value end
    return {
        scenario = args.scenario or "default",
        items = tonumber(args.items),
        players = tonumber(args.players),
    }
end

--- Build a scenario: who plays, what dropped, who enters what, and what the rng
-- says. Pure, so every scenario is fixture-checked for consistency.
--
-- @return plan {
--   scenario, players = { { name, order, chars } }, items = { { link, quantity } },
--   entries = playerName -> array of { itemIdx, char, override, star },
--   revise = playerName -> array (a second SUBMIT, for the revision step) or nil,
--   rolls = scripted rng values or nil, lootMode, absent = { charName } or nil,
--   hostChange = seconds or nil, failDelivery = true or nil,
-- }, or nil plus a reason
function Simulate.Build(scenario, params)
    scenario = scenario or "default"
    params = params or {}
    if not Simulate.SCENARIOS[scenario] then
        return nil, "unknown scenario: " .. tostring(scenario)
    end

    local playerCount = math.max(1, math.min(params.players or 3, #PLAYERS))
    local charCount = 4
    local itemCount = math.max(1, math.min(params.items or 4, #ITEMS))
    if scenario == "chunked" then
        playerCount, itemCount = #PLAYERS, #ITEMS
    end

    local plan = {
        scenario = scenario, players = {}, items = {}, entries = {}, revise = {},
        lootMode = C.LOOT_MODE.ROLL,
    }

    for p = 1, playerCount do
        local src = PLAYERS[p]
        local player = { name = src.name, order = {}, chars = {} }
        for c = 1, charCount do
            local name, class = src.chars[c][1], src.chars[c][2]
            player.order[c] = name
            player.chars[name] = { class = class }
        end
        plan.players[p] = player
    end

    for i = 1, itemCount do
        plan.items[i] = { link = Simulate.FakeLink(ITEMS[i].id, ITEMS[i].name), quantity = 1 }
    end

    -- Scenario shaping.
    if scenario == "duplicate" then
        plan.items[1].quantity = 2
    elseif scenario == "token" then
        plan.items[1] = { link = Simulate.FakeLink(TOKEN.id, TOKEN.name), quantity = 1 }
    elseif scenario == "special" then
        plan.items[1] = { link = Simulate.FakeLink(SPECIAL.id, SPECIAL.name), quantity = 1 }
    elseif scenario == "contested" and #plan.players >= 2 then
        -- Both Simdave and Simanna claim Bonk.
        local second = plan.players[2]
        second.order[#second.order + 1] = "Bonk"
        second.chars["Bonk"] = { class = "WARRIOR" }
    elseif scenario == "abort" then
        plan.hostChange = 3
    elseif scenario == "sk" or scenario == "star" or scenario == "absent" or scenario == "restore" then
        plan.lootMode = C.LOOT_MODE.SK
        if scenario == "absent" then
            -- Two characters stay home: their indices must not move.
            plan.absent = { plan.players[1].order[3] }
            if plan.players[2] then plan.absent[2] = plan.players[2].order[2] end
        elseif scenario == "restore" then
            plan.failDelivery = true
        end
    end

    -- Entries. Default: every player enters their first two characters on every
    -- item, so T1 and T2 are both populated and the tier gate is visible.
    for _, player in ipairs(plan.players) do
        local list = {}
        for i = 1, #plan.items do
            for c = 1, 2 do
                list[#list + 1] = { itemIdx = i, char = player.order[c] }
            end
        end
        plan.entries[player.name] = list
    end

    if scenario == "tie" then
        -- Exactly two T1 entries on item 1, scripted to tie and then split.
        for p, player in ipairs(plan.players) do
            plan.entries[player.name] = (p <= 2) and { { itemIdx = 1, char = player.order[1] } } or {}
        end
        plan.rolls = { 50, 50, 30, 80 }
    elseif scenario == "duplicate" then
        -- One T1 entry and two T2 entries on the two-copy item: the second copy spills.
        plan.entries[plan.players[1].name] = { { itemIdx = 1, char = plan.players[1].order[1] } }
        for p = 2, #plan.players do
            plan.entries[plan.players[p].name] = { { itemIdx = 1, char = plan.players[p].order[2] } }
        end
        plan.rolls = { 40, 90, 20 }
    elseif scenario == "unclaimed" then
        -- Nobody enters item 2.
        for _, player in ipairs(plan.players) do
            local kept = {}
            for _, e in ipairs(plan.entries[player.name]) do
                if e.itemIdx ~= 2 then kept[#kept + 1] = e end
            end
            plan.entries[player.name] = kept
        end
    elseif scenario == "contested" and #plan.players >= 2 then
        -- Both claimants enter Bonk; both entries must be refused.
        table.insert(plan.entries[plan.players[1].name], { itemIdx = 1, char = "Bonk" })
        table.insert(plan.entries[plan.players[2].name], { itemIdx = 1, char = "Bonk" })
    elseif scenario == "token" then
        -- A wrong-class entry on the token (a priest on a Conqueror token is fine,
        -- a warrior is not) alongside eligible ones.
        plan.entries[plan.players[1].name] = { { itemIdx = 1, char = "Simdave" },
                                               { itemIdx = 1, char = "Bonk" } }
    elseif scenario == "star" then
        -- The top of the list enters items 1 and 2 with a star on 2.
        local top = plan.players[1].order[1]
        plan.entries[plan.players[1].name] = { { itemIdx = 1, char = top },
                                               { itemIdx = 2, char = top, star = true } }
        if plan.players[2] then
            plan.entries[plan.players[2].name] = { { itemIdx = 1, char = plan.players[2].order[1] },
                                                   { itemIdx = 2, char = plan.players[2].order[1] } }
        end
    end

    -- The revision step: the first player withdraws from item 1 a second later.
    local first = plan.players[1].name
    local revised = {}
    for _, e in ipairs(plan.entries[first]) do
        if e.itemIdx ~= 1 or scenario == "tie" or scenario == "duplicate" or scenario == "token"
            or scenario == "star" or scenario == "contested" then
            revised[#revised + 1] = e
        end
    end
    if #revised ~= #plan.entries[first] then plan.revise[first] = revised end

    return plan
end

--- Does an OPEN for this plan need more than one chunk? (For the `chunked` scenario.)
function Simulate.OpenChunks(plan)
    local items = {}
    for i, item in ipairs(plan.items) do
        local itemString = ns.ItemInfo.ParseLink(item.link)
        items[i] = { idx = i, itemString = itemString, count = item.quantity }
    end
    local body = ns.Serialize.encodeOpen("Sim-1", 3, 180, items, plan.lootMode)
    return #ns.Serialize.pack(C.OPS.OPEN, body, "1")
end

--------------------------------------------------------------------------------
-- WoW-facing. Nothing below here runs at file scope.
--------------------------------------------------------------------------------

Simulate.active = false

local plan
local frame
local timeline = {}            -- { at, fn }
local clock = 0
local wire = {}                -- loopback deliveries waiting for the next tick
local saved = {}               -- overridden functions and values, restored on finish
local lastSeenSession
local summary = {}

local function say(text)
    ns.Print("|cff88ccff[sim]|r " .. text)
end

local function at(seconds, fn)
    timeline[#timeline + 1] = { at = clock + seconds, fn = fn }
end

--------------------------------------------------------------------------------
-- Overrides
--------------------------------------------------------------------------------

local function override(table_, key, value)
    saved[#saved + 1] = { table_ = table_, key = key, value = table_[key] }
    table_[key] = value
end

local function restoreAll()
    for i = #saved, 1, -1 do
        local s = saved[i]
        s.table_[s.key] = s.value
    end
    saved = {}
end

--- The fake wire: everything sent is delivered back to this client on the next
-- tick, as the real echo would be. Fake players never receive; they watch the
-- local mirror instead.
local function loopback(prefix, message, channel, target)
    wire[#wire + 1] = { prefix = prefix, message = message, channel = channel,
                        sender = UnitName("player") }
end

--- A fake player's message into the host, through the real transport code.
local function fakeSend(sender, op, body)
    for _, chunk in ipairs(ns.Serialize.pack(op, body, tostring(math.random(1, 999)))) do
        wire[#wire + 1] = { prefix = C.PREFIX, message = chunk, channel = "RAID", sender = sender }
    end
end

local function installOverrides()
    local me = UnitName("player")
    local _, myClass = UnitClass("player")

    override(ns.Comms, "transport", loopback)
    override(ns.Comms, "Channel", function() return "RAID" end)
    override(ns.Announce, "transport", function(text, channel, target)
        say("|cffaaaaaa" .. channel .. (target and (" to " .. target) or "") .. ":|r " .. text)
    end)
    override(ns.Session, "HostName", function() return Simulate.hostName end)
    Simulate.hostName = me

    -- The group: this player plus every fake player and every fake character.
    override(ns.Roster, "GroupMembers", function()
        local members = { { name = me, class = myClass, isSelf = true } }
        local absent = {}
        for _, name in ipairs(plan.absent or {}) do absent[name:lower()] = true end
        for _, player in ipairs(plan.players) do
            for _, name in ipairs(player.order) do
                if not absent[name:lower()] then
                    members[#members + 1] = { name = name, class = player.chars[name].class }
                end
            end
        end
        return members
    end)
    ns.Roster.RefreshPresence()

    -- The award click: no GiveMasterLoot, no trade. Delivered on the spot, or failed
    -- terminally for the restore scenario.
    override(ns.Award, "Prompt", function(sessionId, itemIdx, copy)
        local record = ns.Award.Get(sessionId, itemIdx, copy)
        if not record then return false end
        if plan.failDelivery and not Simulate.failedOne then
            Simulate.failedOne = true
            ns.Award.MarkFailed(record, C.AWARD_FAILURE.TRADE_EXPIRED)
        else
            ns.Award.MarkDelivered(record, C.DELIVERY_PATH.MASTER_LOOT)
        end
        return true
    end)

    -- The priority list: a copy, discarded afterwards (section 4).
    local copy = ns.Util.deepCopy(ns.Database.Priority())
    override(ns.Database, "Priority", function() return copy end)
    override(ns.Database.Host(), "lootMode", plan.lootMode)

    if plan.rolls then
        local i = 0
        override(ns.Session, "rng", function(lo, hi)
            i = i + 1
            local v = plan.rolls[i]
            if v == nil then return math.random(lo, hi) end
            return v
        end)
    end
end

--------------------------------------------------------------------------------
-- The fake players
--------------------------------------------------------------------------------

local function publishFakes()
    for _, player in ipairs(plan.players) do
        fakeSend(player.name, C.OPS.HI, C.VERSION)
        local body = ns.Serialize.encodeRoster(player.order, player.chars)
        fakeSend(player.name, C.OPS.ROSTER, body)
    end
end

local function submitFakes(session, which)
    for _, player in ipairs(plan.players) do
        local entries = which == "revise" and plan.revise[player.name] or plan.entries[player.name]
        if entries then
            local body = ns.Serialize.encodeSubmit(session.id, entries)
            fakeSend(player.name, C.OPS.SUBMIT, body)
        end
    end
end

--------------------------------------------------------------------------------
-- Running
--------------------------------------------------------------------------------

local function finish()
    if not Simulate.active then return end
    say("done. " .. table.concat(summary, " "))
    say("The roll window shows the result; the history record is tagged simulated.")
    Simulate.active = false
    plan = nil
    timeline, wire = {}, {}

    -- Whatever is still queued is simulated traffic: a chat line the drain has not
    -- reached, the tail of a chunked ROLLS. It must never meet the real transports.
    ns.Announce.Reset()
    ns.Comms.Reset()

    -- Back to the real world: overrides off, fake rosters and peers forgotten.
    restoreAll()
    for _, name in ipairs({ "Simdave", "Simanna", "Simerin", "Simkate", "Simoli" }) do
        ns.Roster.published[name] = nil
        ns.Session.peers[name] = nil
    end
    ns.Roster.RefreshPresence()
    ns.Roster.Publish()
    -- The abort scenario changed hands; the remembered host must be the real one
    -- again before any real batch opens, or a roster event would abort it.
    ns.Session.CheckHost()
    ns.Client.CheckHost()
    if ns.HostPanel and ns.HostPanel.IsShown() then ns.HostPanel.Refresh() end
    frame:Hide()
end

--- A step failed: say so and put everything back rather than leave the loopback
-- installed for the rest of the session.
local function guarded(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        say("|cffff6060error:|r " .. tostring(err) .. " - stopping the simulation.")
        finish()
    end
    return ok
end

--- `/rls simulate stop`
function Simulate.Stop()
    if not Simulate.active then
        say("no simulation is running.")
        return false
    end
    summary[#summary + 1] = "stopped by hand."
    finish()
    return true
end

local function awardAll(session)
    local delivered, failed = 0, 0
    for _, item in ipairs(session.items) do
        for copy = 1, #(session.awards and session.awards[item.idx] or {}) do
            ns.Award.Prompt(session.id, item.idx, copy)
            local record = ns.Award.Get(session.id, item.idx, copy)
            if record and record.delivery == C.DELIVERY.DELIVERED then delivered = delivered + 1
            else failed = failed + 1 end
        end
    end
    summary[#summary + 1] = string.format("%d delivered, %d failed (stubbed).", delivered, failed)
    if plan.lootMode == C.LOOT_MODE.SK then
        summary[#summary + 1] = string.format("Priority list (copy) now version %d: %s.",
            ns.Priority.Version(), table.concat(ns.Database.Priority().order, " > "))
    end
end

--- The local mirror changed: the fake players react to what it shows.
local function onMirror(session)
    if not Simulate.active or not session then return end
    if session.state == C.SESSION_STATE.OPEN and lastSeenSession ~= session.id then
        lastSeenSession = session.id
        say(string.format("batch %s is open on %d item(s); fake players submit in a second.",
            session.id, #session.items))
        at(1, function() submitFakes(session, "submit") end)
        at(2, function()
            if next(plan.revise) then
                say("a fake player revises.")
                submitFakes(session, "revise")
            end
        end)
        if plan.hostChange then
            at(plan.hostChange, function()
                say("the master looter changes hands mid-batch.")
                Simulate.hostName = plan.players[1].name
                ns.Session.CheckHost()
                ns.Client.CheckHost()
                at(1, finish)
            end)
        else
            at(4, function()
                local host = ns.Session.current
                if host and host.state == C.SESSION_STATE.OPEN then
                    say(string.format("%d of %d fake players in; closing.",
                        #ns.Session.SubmittedNames(host), #plan.players))
                    ns.Session.Close()
                end
            end)
        end
    elseif session.state == C.SESSION_STATE.CLOSED and session.rolls and not Simulate.awarded then
        Simulate.awarded = true
        local host = ns.Session.current
        local lines = {}
        for _, r in ipairs(session.results) do
            lines[#lines + 1] = string.format("item %d: %s", r.itemIdx,
                r.outcome == C.OUTCOME.UNCLAIMED and "unclaimed" or (r.winner .. " (" .. r.outcome .. ")"))
        end
        summary[#summary + 1] = table.concat(lines, "; ") .. "."
        at(0.5, function()
            if host then awardAll(host) end
            at(1, finish)
        end)
    elseif session.state == C.SESSION_STATE.ABORTED then
        summary[#summary + 1] = "aborted: " .. tostring(session.abortReason) .. "."
    end
end

local function onUpdate(_, elapsed)
    clock = clock + elapsed

    -- Deliver the fake wire.
    if #wire > 0 then
        local batch = wire
        wire = {}
        for _, w in ipairs(batch) do
            if not Simulate.active then return end
            guarded(ns.Comms.Receive, w.prefix, w.message, w.channel, w.sender)
        end
    end

    -- Run the timeline.
    local due = {}
    local rest = {}
    for _, step in ipairs(timeline) do
        if clock >= step.at then due[#due + 1] = step else rest[#rest + 1] = step end
    end
    timeline = rest
    for _, step in ipairs(due) do
        if not Simulate.active then return end
        guarded(step.fn)
    end
end

--- `/rls simulate [items=N] [players=N] [scenario=name]`
function Simulate.Run(argument)
    if Simulate.active then
        say("a simulation is already running.")
        return false
    end
    local real = ns.Session.current
    if real and real.state == C.SESSION_STATE.OPEN then
        say("refused: a real batch is open.")
        return false
    end
    if ns.Client.IsOpen() then
        say("refused: a real batch is open on this client.")
        return false
    end

    local args = Simulate.ParseArgs(argument)
    local built, why = Simulate.Build(args.scenario, args)
    if not built then
        say(why .. ". Scenarios: " .. Simulate.ListScenarios())
        return false
    end
    plan = built

    if not frame then
        frame = CreateFrame("Frame", "RaidLootSystemSimulateFrame")
        frame:SetScript("OnUpdate", onUpdate)
        ns.Client.RegisterListener(function(session) guarded(onMirror, session) end)
    end

    Simulate.active = true
    Simulate.awarded, Simulate.failedOne = false, false
    lastSeenSession = nil
    summary = {}
    clock, timeline, wire = 0, {}, {}
    ns.Comms.Reset()
    installOverrides()
    frame:Show()

    say(string.format("scenario %s: %s. %d fake players, %d items, %s.", plan.scenario,
        Simulate.SCENARIOS[plan.scenario], #plan.players, #plan.items, plan.lootMode))
    if plan.scenario == "chunked" then
        summary[#summary + 1] = string.format("OPEN needed %d chunks.", Simulate.OpenChunks(plan))
    end

    publishFakes()
    at(0.5, function()
        if plan.lootMode == C.LOOT_MODE.SK then
            local ok, err = ns.Priority.Seed(true)
            if not ok then
                say("could not seed the copied list: " .. tostring(err))
                finish()
                return
            end
            say("seeded a COPY of the priority list: " .. table.concat(ns.Database.Priority().order, " > "))
        end
    end)
    at(1, function()
        local rows = {}
        for _, item in ipairs(plan.items) do
            rows[#rows + 1] = { quantity = item.quantity, info = ns.ItemInfo.Get(item.link) }
        end
        local items = ns.LootDetect.Collapse(rows)
        local ok, err = ns.Session.Open(items)
        if not ok then
            say("could not open the batch: " .. tostring(err))
            finish()
        end
    end)
    return true
end

function Simulate.ListScenarios()
    local names = {}
    for name in pairs(Simulate.SCENARIOS) do names[#names + 1] = name end
    table.sort(names)
    return table.concat(names, ", ")
end
