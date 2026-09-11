-- Modules/Roster.lua
--
-- Claims, ordering, conflicts and presence (spec 001).
--
-- Everything above the "WoW-facing" divider is pure and fixture-tested by the
-- `roster` suite; the file creates no frame and calls no WoW API while loading.

local ADDON, ns = ...

ns.Roster = {}
local Roster = ns.Roster

local C = ns.Constants
local Util = ns.Util
local Tiers = ns.Tiers
local Serialize = ns.Serialize

local VALID_CLASS = {}
for _, class in ipairs(C.CLASSES) do VALID_CLASS[class] = true end

--------------------------------------------------------------------------------
-- Pure: invariants
--------------------------------------------------------------------------------

--- Check the section 2 invariants over a roster.
-- @return true, or nil plus a human-readable reason
function Roster.Validate(order, chars)
    if type(order) ~= "table" or type(chars) ~= "table" then
        return nil, "roster is not a table"
    end

    local seen, selves = {}, 0
    for i = 1, #order do
        local name = order[i]
        if type(name) ~= "string" or name == "" then
            return nil, "position " .. i .. " has no name"
        end
        local key = name:lower()
        if seen[key] then return nil, "duplicate character: " .. name end
        seen[key] = true

        local entry = chars[name]
        if not entry then return nil, "no class recorded for " .. name end
        if not VALID_CLASS[entry.class or ""] then
            return nil, "unknown class for " .. name .. ": " .. tostring(entry.class)
        end
    end

    -- `chars` is global and `order` is one campaign's hierarchy (spec 012 section 4),
    -- so a character with a class and no position is the ordinary state of one you
    -- did not bring to this campaign -- not a broken roster. Only the ordering is
    -- checked for duplicates and unknown classes.
    for name, entry in pairs(chars) do
        if not VALID_CLASS[entry.class or ""] then
            return nil, "unknown class for " .. name .. ": " .. tostring(entry.class)
        end
        if entry.isSelf then selves = selves + 1 end
    end

    if selves > 1 then return nil, "more than one character is marked as your own" end
    return true
end

--- Point the "you" marker at the character being played (section 2, invariant 3).
--
-- The roster is saved per account, so the marker belongs to whoever is logged in
-- now -- not to whichever character happened to be logged in when the roster was
-- built. A character absent from the roster leaves every entry unmarked, which the
-- invariant allows.
--
-- @return true when something changed, so the caller can redraw
function Roster.MarkSelf(chars, playerName)
    local key = type(playerName) == "string" and playerName:lower() or nil
    local changed = false
    for name, entry in pairs(chars or {}) do
        local isSelf = key ~= nil and name:lower() == key
        if (entry.isSelf == true) ~= isSelf then
            entry.isSelf = isSelf
            changed = true
        end
    end
    return changed
end

--------------------------------------------------------------------------------
-- Pure: inferring a class (section 4)
--
-- A class is only ever recorded because something in the game said so. Nothing
-- asks the player to type one: a character typed in as the wrong class filters
-- itself off every item it could have used, or onto items it cannot equip, and
-- the roll window has no way to tell that from a real answer.
--------------------------------------------------------------------------------

--- The first source that names a class for this character.
--
-- @param candidates array of { from, class }, most directly observed first;
--        entries with no class, or a class this build does not know, are skipped
--        rather than trusted -- a lookup that has drifted returns nil or a
--        localised string, and either must fail loudly instead of writing a
--        nonsense class into the roster.
-- @return class, source description; or nil when nothing knows
function Roster.KnownClass(candidates)
    for _, candidate in ipairs(candidates or {}) do
        if VALID_CLASS[candidate.class or ""] then
            return candidate.class, candidate.from
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Pure: the claim index (section 5)
--
-- A conflict is two different players publishing the same character name. The
-- addon never picks a winner; it marks the character contested and refuses to
-- let anyone enter it.
--------------------------------------------------------------------------------

--- @param published map of player name -> { order = {...} }
-- @return map of lowercased character name -> { name, owners = {...}, contested }
function Roster.BuildClaims(published)
    local claims = {}
    local players = {}
    for player in pairs(published) do players[#players + 1] = player end
    table.sort(players)          -- deterministic owner order, so messages are stable

    for _, player in ipairs(players) do
        local entry = published[player]
        for _, name in ipairs(entry.order or {}) do
            local key = name:lower()
            local claim = claims[key]
            if not claim then
                claims[key] = { name = name, owners = { player }, contested = false }
            else
                local already = false
                for _, owner in ipairs(claim.owners) do
                    if owner:lower() == player:lower() then already = true end
                end
                if not already then
                    claim.owners[#claim.owners + 1] = player
                    claim.contested = true
                end
            end
        end
    end
    return claims
end

--------------------------------------------------------------------------------
-- Pure: the hierarchy lock (spec 014)
--------------------------------------------------------------------------------

--- Is this change to an already-submitted hierarchy allowed while locked?
--
-- A tier is the first gate on every item, so re-ranking between raid nights is the
-- cheapest way to take one: move your main to T1 the evening before the boss that
-- drops what you want. The lock exists to stop that, not to freeze a roster.
--
-- What survives the lock is appending. A character added at the end of your own
-- ordering lands in Rest, below everyone you had already ranked, so it can jump
-- nobody -- and without this a bot rolled mid-campaign could never be brought in at
-- all. Everything else is refused: a reorder is the whole point of the lock, and a
-- removal is a reorder wearing a disguise, because taking out your T1 promotes
-- every character below it by one.
-- @return true, or nil plus a reason
function Roster.LockedChangeAllowed(storedOrder, incomingOrder)
    storedOrder, incomingOrder = storedOrder or {}, incomingOrder or {}
    for i = 1, #storedOrder do
        local was, now = storedOrder[i], incomingOrder[i]
        if now == nil then
            return nil, "characters cannot be removed from a locked hierarchy"
        end
        if tostring(was):lower() ~= tostring(now):lower() then
            return nil, "characters cannot be re-ranked in a locked hierarchy"
        end
    end
    return true
end

--- "contested - Steve and Dave both claim Sneaky" (section 5).
function Roster.ContestReason(claim)
    local owners = claim.owners
    local list
    if #owners == 2 then
        list = owners[1] .. " and " .. owners[2]
    else
        list = table.concat(owners, ", ", 1, #owners - 1) .. " and " .. owners[#owners]
    end
    return "contested - " .. list .. " both claim " .. claim.name
end

--------------------------------------------------------------------------------
-- Pure: export and import (section 8)
--
-- The same encoding as ROSTER, prefixed with "RLS1:".
--------------------------------------------------------------------------------

function Roster.Encode(order, chars)
    local body, err = Serialize.encodeRoster(order, chars)
    if not body then return nil, err end
    return C.EXPORT_PREFIX .. body
end

--- Parse an import string without applying it.
-- Rejects the whole string on any failure rather than importing partially.
-- @return order, chars, or nil plus a reason
function Roster.ParseImport(text)
    if type(text) ~= "string" then return nil, "nothing to import" end
    text = Util.trim(text)
    if text == "" then return nil, "nothing to import" end

    local prefix = C.EXPORT_PREFIX
    if text:sub(1, #prefix) ~= prefix then
        return nil, "this is not a RaidLootSystem roster string"
    end

    local order, chars = Serialize.decodeRoster(text:sub(#prefix + 1))
    if not order then return nil, chars end
    if #order == 0 then return nil, "the roster string is empty" end

    local ok, why = Roster.Validate(order, chars)
    if not ok then return nil, why end
    return order, chars
end

--------------------------------------------------------------------------------
-- Pure: hierarchies against the character table (spec 012 section 7)
--
-- The character table is global and every hierarchy names into it. A hierarchy
-- naming a character that is gone is invisible: Campaign.HierarchyRows filters it
-- out of the display, so displayed positions and stored indices diverge and a move
-- reorders the wrong pair.
--------------------------------------------------------------------------------

--- Drop from `list` every name `chars` no longer holds. Mutates and returns it.
function Roster.PruneToChars(list, chars)
    local known = {}
    for name in pairs(chars or {}) do known[name:lower()] = true end
    for i = #list, 1, -1 do
        if not known[tostring(list[i]):lower()] then table.remove(list, i) end
    end
    return list
end

--- Append to `template` every name in `order` it does not already hold, the way
-- Roster.Add appends a character it has just created. An import replaces the whole
-- character table, so a template that was only pruned ends up holding whatever the
-- old and new rosters happen to share -- usually nothing. It is the seed for every
-- new campaign and every join, and an empty one opens those dialogs with nothing
-- ticked. Mutates and returns it.
function Roster.SeedTemplate(template, order)
    local held = {}
    for _, name in ipairs(template) do held[tostring(name):lower()] = true end
    for _, name in ipairs(order or {}) do
        local key = tostring(name):lower()
        if not held[key] then
            held[key] = true
            template[#template + 1] = name
        end
    end
    return template
end

--- The labels of the campaigns an import would strip characters from, sorted.
--
-- The active campaign is excluded: the import replaces its ordering outright, which
-- is the thing the player asked for. Every other campaign loses names silently, and
-- saying so is what makes the confirmation honest about what it destroys.
--
-- @param campaigns  map of id -> campaign
-- @param chars      the character table the import would install
-- @param activeId   the campaign whose ordering the import replaces
function Roster.ImportLosses(campaigns, chars, activeId)
    local known = {}
    for name in pairs(chars or {}) do known[name:lower()] = true end
    -- Campaign labels are cosmetic, not unique (Campaign.ValidLabel never checks
    -- for a collision), so two distinct campaigns can print the same string here.
    -- Dedupe rather than list a label twice with nothing to tell them apart.
    local seen, labels = {}, {}
    for id, campaign in pairs(campaigns or {}) do
        if id ~= activeId then
            local lost = false
            for _, name in ipairs(campaign.hierarchy or {}) do
                if not known[tostring(name):lower()] then lost = true end
            end
            local label = tostring(campaign.label or id)
            if lost and not seen[label] then
                seen[label] = true
                labels[#labels + 1] = label
            end
        end
    end
    table.sort(labels)
    return labels
end

--------------------------------------------------------------------------------
-- WoW-facing state. Nothing below here runs at file scope.
--------------------------------------------------------------------------------

Roster.published = {}        -- player -> { order, chars }
Roster.claims = {}           -- from BuildClaims
local presence = {}          -- lowercased character name -> true
local listeners = {}
local warnedLocked = {}      -- sender -> true, once per login session
local frame

--- The active campaign's hierarchy plus the global character table, in the shape
-- the rest of this file already expected (spec 012 section 4). No active
-- campaign reads as an empty order, not a crash: there is nothing ranked in a
-- campaign that does not exist.
local function DB()
    local roster = ns.Database.Roster()
    return { order = ns.Database.Hierarchy() or {}, chars = roster.chars }
end

--- Forget what other players published. Claims are rebuilt for the active campaign
-- only (spec 012 section 8), so switching campaigns starts the index over.
function Roster.ResetPublished()
    Roster.published = {}
    Roster.claims = {}
end

--- UI redraws on this rather than polling.
function Roster.RegisterListener(fn)
    listeners[#listeners + 1] = fn
end

local function fireChanged()
    for _, fn in ipairs(listeners) do fn() end
end

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------

function Roster.Order() return DB().order end
function Roster.Chars() return DB().chars end

function Roster.PositionOf(name)
    return Util.indexOf(DB().order, name)
end

--- Canonical stored name for a case-insensitive lookup, or nil.
function Roster.Resolve(name)
    local position = Roster.PositionOf(name)
    return position and DB().order[position] or nil
end

function Roster.ClassOf(name)
    local stored = Roster.Resolve(name)
    local entry = stored and DB().chars[stored]
    return entry and entry.class or nil
end

--- Class of any character in the raid, which may belong to another player:
-- ours first, then whoever published it. The fallback several UI screens need
-- for characters that are on someone else's roster, not ours.
function Roster.ClassOfAny(name)
    return Roster.ClassOf(name) or Roster.PublishedClassOf(name)
end

function Roster.SelfName()
    for name, entry in pairs(DB().chars) do
        if entry.isSelf then return name end
    end
    return nil
end

--- Tier of a character under the given tier count. nil when not in the roster.
function Roster.TierFor(name, tierCount)
    local position = Roster.PositionOf(name)
    if not position then return nil end
    return Tiers.forPosition(position, tierCount or ns.Database.DefaultTierCount())
end

--------------------------------------------------------------------------------
-- Writing. Every write validates, then publishes.
--------------------------------------------------------------------------------

local function commit(order, chars, silent)
    local ok, why = Roster.Validate(order, chars)
    if not ok then return nil, why end

    -- The ordering belongs to the active campaign; the characters are global.
    -- With no active campaign there is nowhere to put `order` -- it was built
    -- from an empty starting list in the first place (see DB() above) -- but the
    -- character table still writes, so adding a character works before a
    -- campaign exists; it just is not ranked anywhere yet.
    local campaign = ns.Campaign.Active()
    if campaign then campaign.hierarchy = order end
    ns.Database.Roster().chars = chars
    if not silent then
        Roster.Publish()
        fireChanged()
    end
    return true
end

--- Add a character. Class is the enUS file name, never the localised string.
function Roster.Add(name, class, isSelf)
    if type(name) ~= "string" or Util.trim(name) == "" then
        return nil, "no name given"
    end
    name = Util.trim(name)
    if not VALID_CLASS[class or ""] then
        return nil, "unknown class: " .. tostring(class)
    end
    if Roster.PositionOf(name) then
        return nil, name .. " is already in your roster"
    end

    local claim = Roster.claims[name:lower()]
    if claim and not Roster.ClaimedByMe(name) then
        -- Adding it anyway is legal but creates a conflict, so say what happens.
        ns.Print(string.format("%s is already claimed by %s. Adding it makes the character "
            .. "contested and nobody will be able to enter it until one of you removes it.",
            name, table.concat(claim.owners, ", ")))
    end

    local order = Util.copy(DB().order)
    local chars = Util.deepCopy(DB().chars)
    order[#order + 1] = name
    chars[name] = { class = class, isSelf = isSelf and true or false }

    -- A character you have just added belongs in the template new campaigns are
    -- seeded from, or the seeding would be wrong the moment you join one.
    local template = ns.Database.DefaultHierarchy()
    if not Util.indexOf(template, name) then template[#template + 1] = name end

    return commit(order, chars)
end

--- Drop from every campaign's hierarchy and from the template any name the character
-- table no longer holds.
local function pruneHierarchies(chars)
    for _, campaign in pairs(ns.Database.Campaigns()) do
        Roster.PruneToChars(campaign.hierarchy or {}, chars)
    end
    Roster.PruneToChars(ns.Database.DefaultHierarchy(), chars)
end

--- Take a character out of your roster entirely: it is global, so it leaves every
-- campaign's hierarchy and the template with it. Leaving a dangling name behind
-- would make the campaigns you are not looking at fail validation.
function Roster.Remove(name)
    local stored = Roster.Resolve(name) or name
    local chars = Util.deepCopy(DB().chars)
    if chars[stored] == nil then return nil, "not in your roster" end

    -- A removal is a re-rank: everything below it moves up a place. So it is
    -- refused exactly like the untick beside it while any campaign that ranks this
    -- character is locked (spec 014).
    for campaignId, campaign in pairs(ns.Database.Campaigns()) do
        if Util.indexOf(campaign.hierarchy or {}, stored)
            and ns.Campaign.HierarchyLocked(campaignId) then
            return nil, string.format("\"%s\" has started and its hierarchies are locked, and "
                .. "%s is ranked in it. The master looter can unlock them in the host panel.",
                ns.Campaign.LabelFor(campaignId), stored)
        end
    end

    chars[stored] = nil

    pruneHierarchies(chars)

    return commit(Util.copy(DB().order), chars)
end

--- Move a character to a new position, shifting the rest.
function Roster.Move(from, to)
    local order = Util.copy(DB().order)
    if not Util.move(order, from, to) then return nil, "position out of range" end
    return commit(order, Util.deepCopy(DB().chars))
end

function Roster.MoveUp(position)   return Roster.Move(position, position - 1) end
function Roster.MoveDown(position) return Roster.Move(position, position + 1) end

--------------------------------------------------------------------------------
-- Editing one campaign's hierarchy, or the template (spec 012 section 7)
--
-- The editor grows a campaign picker, so it edits a named list rather than always
-- the active one. `roster.defaultHierarchy` is reachable through the same calls
-- under the key "default"; it resolves nothing and is never published.
--------------------------------------------------------------------------------

Roster.DEFAULT_TARGET = "default"

--- The array a target names, or nil.
function Roster.HierarchyList(target)
    if target == nil or target == ns.Campaign.ActiveId() then return ns.Database.Hierarchy() end
    if target == Roster.DEFAULT_TARGET then return ns.Database.DefaultHierarchy() end
    return ns.Database.Hierarchy(target)
end

--- After any edit to one campaign's hierarchy.
--
-- The edit is recorded against that campaign whether or not it is the active one.
-- Publishing only covers the active campaign, so without this an edit to a campaign
-- you are not currently in would leave your own row in its tier roster showing the
-- ordering you last broadcast rather than the one you just made -- two answers to
-- "what did Matt rank", with the wrong one on screen (spec 013 section 3).
--
-- The template resolves nothing and is broadcast to nobody, so it records nothing.
local function afterEdit(target)
    if target == Roster.DEFAULT_TARGET then
        fireChanged()
        return true
    end
    local campaignId = target or ns.Campaign.ActiveId()
    local me = UnitName("player")
    if me and campaignId then
        ns.Campaign.RecordHierarchy(campaignId, me, Roster.HierarchyList(campaignId),
            ns.Database.Roster().chars)
    end
    if campaignId == ns.Campaign.ActiveId() then
        Roster.Publish()
    end
    fireChanged()
    return true
end

--- Why this campaign's hierarchy cannot be edited right now, or nil. The template
-- is never locked: it resolves nothing and seeds campaigns that have not begun.
local function lockedReason(target)
    if target == Roster.DEFAULT_TARGET then return nil end
    local campaignId = target or ns.Campaign.ActiveId()
    if not ns.Campaign.HierarchyLocked(campaignId) then return nil end
    return string.format("\"%s\" has started and its hierarchies are locked. The master "
        .. "looter can unlock them in the host panel.", ns.Campaign.LabelFor(campaignId))
end

--- Reorder inside one hierarchy.
function Roster.MoveIn(target, from, to)
    local list = Roster.HierarchyList(target)
    if not list then return nil, "no such campaign" end
    local locked = lockedReason(target)
    if locked then return nil, locked end
    if not Util.move(list, from, to) then return nil, "position out of range" end
    return afterEdit(target)
end

--- Tick or untick a character for one campaign. A character absent from a
-- campaign's hierarchy does not participate in it; it is not unclaimed, and it
-- keeps its row so it can always be re-ticked.
function Roster.SetIncludedIn(target, name, included)
    local list = Roster.HierarchyList(target)
    if not list then return nil, "no such campaign" end
    local chars = ns.Database.Roster().chars
    local stored = name
    for stored_ in pairs(chars) do
        if stored_:lower() == (name or ""):lower() then stored = stored_ end
    end
    if not chars[stored] then return nil, stored .. " is not in your roster" end

    local at = Util.indexOf(list, stored)
    if included and not at then
        -- Allowed even while locked: it appends, so it lands in Rest and jumps
        -- nobody (spec 014). Without it a character rolled mid-campaign could
        -- never be brought in at all.
        list[#list + 1] = stored
    elseif not included and at then
        local locked = lockedReason(target)
        if locked then return nil, locked end
        table.remove(list, at)
    else
        return true
    end
    return afterEdit(target)
end

--------------------------------------------------------------------------------
-- Claiming from the game (section 4)
--------------------------------------------------------------------------------

--- Add the current target.
function Roster.AddTarget()
    if not UnitExists("target") then return nil, "you have no target" end
    if not UnitIsPlayer("target") then return nil, "your target is not a player" end
    local name = UnitName("target")
    local _, class = UnitClass("target")
    return Roster.Add(name, class, UnitIsUnit("target", "player"))
end

--------------------------------------------------------------------------------
-- Adding by name (section 4)
--
-- Every source below observed the class in game. The guild roster is the only one
-- that answers for a character who is offline right now, which is the whole reason
-- adding by name exists -- an alt you can target or group with is already covered
-- by Add target and Add group.
--------------------------------------------------------------------------------

--- Class recorded for this character in another player's published roster. They
-- captured it from the game the same way we would have.
function Roster.PublishedClassOf(name)
    local key = name:lower()
    for _, published in pairs(Roster.published) do
        for n, entry in pairs(published.chars or {}) do
            if n:lower() == key then return entry.class end
        end
    end
    return nil
end

--- Class from the guild roster, which lists offline members too.
--
-- The 11th return of `GetGuildRosterInfo` is the enUS class token in 3.3.5a (the
-- 5th is the localised display name -- never that one). It is validated by the
-- caller rather than trusted: if that position ever moves, the lookup reports "not
-- known" and the add is refused, instead of silently writing whatever came back.
function Roster.GuildClassOf(name)
    if not IsInGuild() then return nil end
    local key = name:lower()
    for i = 1, GetNumGuildMembers() do
        local member, _, _, _, _, _, _, _, _, _, class = GetGuildRosterInfo(i)
        if not member then break end
        if member:lower() == key then return class end
    end
    return nil
end

--- Everything on this client that can name the character's class, best first.
function Roster.ClassSources(name)
    local key = name:lower()
    local sources = {}

    for _, member in ipairs(Roster.GroupMembers()) do
        if member.name and member.name:lower() == key then
            sources[#sources + 1] = { from = "the group", class = member.class }
        end
    end
    sources[#sources + 1] = { from = "a published roster", class = Roster.PublishedClassOf(name) }
    sources[#sources + 1] = { from = "your guild roster", class = Roster.GuildClassOf(name) }
    return sources
end

--- Add a character typed in by name, inferring the class (section 4).
--
-- Refuses rather than guessing. The player has no way to assert a class here, so a
-- roster entry always carries a class something in the game reported.
-- @return true plus the class and where it came from, or nil plus a reason
function Roster.AddByName(name)
    if type(name) ~= "string" or Util.trim(name) == "" then return nil, "no name given" end
    name = Util.trim(name)
    if Roster.PositionOf(name) then return nil, name .. " is already in your roster" end

    local class, from = Roster.KnownClass(Roster.ClassSources(name))
    if not class then
        return nil, string.format("%s's class is not known on this client. Target them and use "
            .. "Add target, add them from the group, or bring them online in your guild - the "
            .. "class is never typed in, so it cannot be wrong.", name)
    end

    local me = UnitName("player")
    local ok, why = Roster.Add(name, class, me ~= nil and name:lower() == me:lower())
    if not ok then return nil, why end
    return true, class, from
end

--- Add everyone in the group who is not already claimed by another player.
-- @return added count, skipped count, array of skip reasons
function Roster.AddAllInGroup()
    local added, skipped, reasons = 0, 0, {}

    for _, member in ipairs(Roster.GroupMembers()) do
        if Roster.PositionOf(member.name) then
            -- already yours, nothing to report
        elseif Roster.claims[member.name:lower()] then
            skipped = skipped + 1
            local claim = Roster.claims[member.name:lower()]
            reasons[#reasons + 1] = member.name .. " is claimed by " ..
                table.concat(claim.owners, ", ")
        else
            local ok, why = Roster.Add(member.name, member.class, member.isSelf)
            if ok then
                added = added + 1
            else
                skipped = skipped + 1
                reasons[#reasons + 1] = member.name .. ": " .. tostring(why)
            end
        end
    end

    return added, skipped, reasons
end

--- Add the player's own character on first run.
function Roster.EnsureSelf()
    if #DB().order > 0 then return end
    local name = UnitName("player")
    local _, class = UnitClass("player")
    if name and class then Roster.Add(name, class, true) end
end

--- Move the "you" marker onto the character being played. Called at login, because
-- the roster outlives any one character: adding an alt from your main and then
-- logging into that alt must not leave "you" on the main.
function Roster.SyncSelf()
    if not Roster.MarkSelf(DB().chars, UnitName("player")) then return false end
    -- isSelf is local knowledge and is not transmitted, so nothing is republished.
    fireChanged()
    return true
end

--------------------------------------------------------------------------------
-- Presence (section 6). Cached: the roll window queries this per character per
-- item, so it must not scan the raid each time.
--------------------------------------------------------------------------------

--- Every character currently in the raid or party, including the player.
function Roster.GroupMembers()
    local members = {}
    local me = UnitName("player")
    local raidCount = GetNumRaidMembers()

    if raidCount > 0 then
        for i = 1, raidCount do
            local name, _, _, _, _, class = GetRaidRosterInfo(i)
            if name then
                members[#members + 1] = { name = name, class = class,
                                          isSelf = (me ~= nil and name == me) }
            end
        end
    else
        local _, myClass = UnitClass("player")
        members[#members + 1] = { name = me, class = myClass, isSelf = true }
        for i = 1, GetNumPartyMembers() do
            local unit = "party" .. i
            local name = UnitName(unit)
            local _, class = UnitClass(unit)
            if name then
                members[#members + 1] = { name = name, class = class, isSelf = false }
            end
        end
    end
    return members
end

function Roster.RefreshPresence()
    presence = {}
    for _, member in ipairs(Roster.GroupMembers()) do
        if member.name then presence[member.name:lower()] = true end
    end
    fireChanged()
end

function Roster.IsPresent(name)
    return name ~= nil and presence[name:lower()] == true
end

--- Group members in nobody's published roster. Surfaced by the host panel (006).
function Roster.UnclaimedGroupMembers()
    local out = {}
    for _, member in ipairs(Roster.GroupMembers()) do
        if member.name and not Roster.claims[member.name:lower()] then
            out[#out + 1] = member.name
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- Conflicts and entry gating
--------------------------------------------------------------------------------

function Roster.ClaimedByMe(name)
    local claim = Roster.claims[name and name:lower() or ""]
    if not claim then return false end
    local me = UnitName("player")
    for _, owner in ipairs(claim.owners) do
        if me and owner:lower() == me:lower() then return true end
    end
    return false
end

function Roster.IsContested(name)
    local claim = Roster.claims[name and name:lower() or ""]
    return claim ~= nil and claim.contested == true
end

function Roster.ContestedNames()
    local out = {}
    for _, claim in pairs(Roster.claims) do
        if claim.contested then out[#out + 1] = claim.name end
    end
    table.sort(out)
    return out
end

--- May this character be entered into a roll?
-- @return true, or false plus a reason code and a message for the roll window
function Roster.Enterable(name)
    if not Roster.PositionOf(name) then
        return false, C.REASON.NOT_OWNED, name .. " is not in your roster"
    end
    local claim = Roster.claims[name:lower()]
    if claim and claim.contested then
        return false, C.REASON.CONTESTED, Roster.ContestReason(claim)
    end
    if not Roster.IsPresent(name) then
        return false, C.REASON.NOT_PRESENT, name .. " is not in the raid"
    end
    return true
end

--------------------------------------------------------------------------------
-- Publishing (section 5)
--------------------------------------------------------------------------------

local function rebuildClaims()
    Roster.claims = Roster.BuildClaims(Roster.published)
    fireChanged()
end

--- Broadcast this player's ordered roster for the active campaign. ROSTER carries
-- the campaign id (spec 012 section 10), which is what makes the claim index of
-- spec 001 section 5 per campaign as a consequence.
--
-- With no active campaign there is nothing to publish: the message would name no
-- campaign, every receiver would reject it as unreadable in chat, and the roster
-- events this hangs off fire often enough to do that repeatedly. Nothing is sent
-- until the player is in a campaign.
function Roster.Publish()
    local campaign = ns.Campaign.Active()
    if not campaign then return end

    local roster = DB()
    local body, err = Serialize.encodeRosterMsg(campaign.id, roster.order, roster.chars)
    if not body then
        ns.Print("could not publish your roster: " .. tostring(err))
        return
    end

    -- Record our own claim locally too, so conflicts show without a round trip.
    local me = UnitName("player")
    if me then
        Roster.published[me] = { order = Util.copy(roster.order),
                                 chars = Util.deepCopy(roster.chars) }
        -- And our own submission onto the campaign, by the same rule that stores
        -- everyone else's (spec 013 section 3): the roster must name us whether or
        -- not anyone was online to hear the broadcast.
        ns.Campaign.RecordHierarchy(campaign.id, me, roster.order, roster.chars)
        rebuildClaims()
    end

    ns.Comms.Send(C.OPS.ROSTER, body)
end

--- Ask everyone to resend their roster. Not host-only: Campaign.Switch calls it from
-- any client, because the members already in the campaign being switched to have no
-- event of their own to republish on and their entries would be rejected as
-- NOT_PUBLISHED (spec 012 section 8).
function Roster.RequestAll()
    ns.Comms.Send(C.OPS.RREQ, "")
end

local function onRoster(sender, body)
    local msg, why = Serialize.decodeRosterMsg(body)
    if not msg then
        ns.Print(string.format("%s sent a roster that could not be read (%s); it was ignored.",
            tostring(sender), tostring(why)))
        return
    end
    -- Recording and claiming are separate steps (spec 013 section 3).
    --
    -- The ordering is stored against whichever campaign it names, provided we are a
    -- member of it, because the tier assignment is a property of that campaign and
    -- has to survive a reload, a switch and the raid ending. A ROSTER for a campaign
    -- we are not in is still dropped and logged (spec 012 section 10).
    if not ns.Campaign.IsMemberOf(msg.campaignId) then
        ns.Debug(string.format("dropped ROSTER from %s: it names campaign %s, which you "
            .. "are not in", tostring(sender), tostring(msg.campaignId)))
        return
    end
    -- The lock is enforced here as well as in the sender's own editor (spec 014).
    -- A member running a build that predates the lock, or one who has edited the
    -- saved variables directly, would otherwise walk straight past it -- and this is
    -- the copy the host stamps entry tiers from, so this is where it has to hold.
    -- The stored ordering stands, the change is refused, and it is said out loud
    -- rather than dropped quietly.
    local stored = ns.Campaign.StoredOrder(msg.campaignId, sender, msg.order)
    if stored and ns.Campaign.HierarchyLocked(msg.campaignId) then
        local ok, why = Roster.LockedChangeAllowed(stored, msg.order)
        if not ok then
            -- Once per sender per login session: a diverged client republishes on
            -- every roster event, and an unbounded repeat buries the raid's chat
            -- (the same rule spec 002 section 11 uses).
            local line = string.format("%s changed their hierarchy but \"%s\" is locked (%s); "
                .. "their ranking is unchanged.", tostring(sender),
                ns.Campaign.LabelFor(msg.campaignId), tostring(why))
            if warnedLocked[sender] then ns.Debug(line) else
                warnedLocked[sender] = true
                ns.Print(line)
            end
            msg.order = Util.copy(stored)
        end
    end

    ns.Campaign.RecordHierarchy(msg.campaignId, sender, msg.order, msg.chars)

    -- The claim index, though, is rebuilt for the ACTIVE campaign only (spec 012
    -- section 8): you never need claims for a campaign you are not raiding in, and
    -- letting one in would make two players claiming a character in unrelated
    -- groups read as a conflict.
    if msg.campaignId ~= ns.Campaign.ActiveId() then return end
    Roster.published[sender] = { order = msg.order, chars = msg.chars }
    rebuildClaims()
end

local function onRosterRequest(sender)
    if ns.Comms.IsSelf(sender) then return end
    Roster.Publish()
end

--------------------------------------------------------------------------------
-- Import / export (section 8)
--------------------------------------------------------------------------------

function Roster.Export()
    local roster = DB()
    return Roster.Encode(roster.order, roster.chars)
end

--- Apply a parsed import. Destructive, so the UI confirms before calling this.
function Roster.ApplyImport(order, chars)
    -- isSelf is not transmitted, so re-derive it from the character being played.
    local me = UnitName("player")
    for name, entry in pairs(chars) do
        entry.isSelf = (me ~= nil and name:lower() == me:lower())
    end
    -- Validated before anything is dropped: a refused import must leave the other
    -- campaigns exactly as it found them.
    local ok, why = Roster.Validate(order, chars)
    if not ok then return nil, why end
    -- The character table is replaced wholesale, so every other campaign's hierarchy
    -- can be left naming a character this import dropped.
    pruneHierarchies(chars)
    -- Pruning alone empties the template, which seeds every new campaign and every
    -- join (spec 012 section 7); the imported ordering is what belongs in it now.
    Roster.SeedTemplate(ns.Database.DefaultHierarchy(), order)
    return commit(order, chars)
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

function Roster.Init()
    if frame then return end

    ns.Comms.RegisterHandler(C.OPS.ROSTER, onRoster)
    ns.Comms.RegisterHandler(C.OPS.RREQ, onRosterRequest)

    frame = CreateFrame("Frame", "RaidLootSystemRosterFrame")
    frame:RegisterEvent("RAID_ROSTER_UPDATE")
    frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
    frame:SetScript("OnEvent", function()
        Roster.RefreshPresence()
        Roster.Publish()
    end)

    Roster.EnsureSelf()
    Roster.SyncSelf()
    Roster.RefreshPresence()
    Roster.Publish()
end
