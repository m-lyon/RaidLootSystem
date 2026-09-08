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
        if entry.isSelf then selves = selves + 1 end
    end

    for name in pairs(chars) do
        if not seen[name:lower()] then
            return nil, name .. " has a class but no position in the order"
        end
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
-- WoW-facing state. Nothing below here runs at file scope.
--------------------------------------------------------------------------------

Roster.published = {}        -- player -> { order, chars }
Roster.claims = {}           -- from BuildClaims
local presence = {}          -- lowercased character name -> true
local listeners = {}
local frame

local function DB() return ns.Database.Roster() end

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

    local roster = DB()
    roster.order, roster.chars = order, chars
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
    return commit(order, chars)
end

function Roster.Remove(name)
    local position = Roster.PositionOf(name)
    if not position then return nil, "not in your roster" end

    local order = Util.copy(DB().order)
    local chars = Util.deepCopy(DB().chars)
    local stored = table.remove(order, position)
    chars[stored] = nil
    return commit(order, chars)
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

--- Broadcast this player's full ordered roster.
function Roster.Publish()
    local roster = DB()
    local body, err = Serialize.encodeRoster(roster.order, roster.chars)
    if not body then
        ns.Print("could not publish your roster: " .. tostring(err))
        return
    end

    -- Record our own claim locally too, so conflicts show without a round trip.
    local me = UnitName("player")
    if me then
        Roster.published[me] = { order = Util.copy(roster.order),
                                 chars = Util.deepCopy(roster.chars) }
        rebuildClaims()
    end

    ns.Comms.Send(C.OPS.ROSTER, body)
end

--- Host-side: ask everyone to resend their roster.
function Roster.RequestAll()
    ns.Comms.Send(C.OPS.RREQ, "")
end

local function onRoster(sender, body)
    local order, chars = Serialize.decodeRoster(body)
    if not order then
        ns.Print(string.format("%s sent a roster that could not be read (%s); it was ignored.",
            tostring(sender), tostring(chars)))
        return
    end
    Roster.published[sender] = { order = order, chars = chars }
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
