-- Core/PriorityList.lua
--
-- The Suicide Kings list (spec 010 section 4): seed, suicide, restore, roster churn,
-- and replay. Pure Lua, no WoW API. Nothing here mutates its arguments; every
-- function returns a new order. Randomness is injected, and the seeded generator
-- lives here so that "here is the seed, run it yourself" is literally true.

local ADDON, ns = ...

ns.PriorityList = {}
local PriorityList = ns.PriorityList

local Util = ns.Util

local function keyOf(name)
    return type(name) == "string" and name:lower() or name
end

--------------------------------------------------------------------------------
-- The seeded generator (section 5)
--------------------------------------------------------------------------------
-- Park-Miller minimal standard: state * 16807 mod (2^31 - 1). Every product stays
-- below 2^53, so it is exact in Lua 5.1's doubles on every platform, which is what
-- makes the shuffle reproducible from the published seed.

local M = 2147483647
local A = 16807

--- An rng(lo, hi) whose sequence is fixed by `seed`.
function PriorityList.rngFrom(seed)
    local state = math.floor(math.abs(tonumber(seed) or 0)) % M
    if state == 0 then state = 1 end
    return function(lo, hi)
        state = (state * A) % M
        return lo + (state % (hi - lo + 1))
    end
end

--------------------------------------------------------------------------------
-- Seeding (section 5)
--------------------------------------------------------------------------------

--- A Fisher-Yates shuffle of `chars`, driven by `rng`. The caller fixes the input
-- order (sorted names), so the same seed over the same characters gives the same list.
function PriorityList.seed(chars, rng)
    local order = {}
    for i = 1, #chars do order[i] = chars[i] end
    for i = #order, 2, -1 do
        local j = rng(1, i)
        order[i], order[j] = order[j], order[i]
    end
    return order
end

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------

function PriorityList.indexOf(order, char)
    return Util.indexOf(order, char)
end

--- name -> index, for Core/Resolve's opts.priority.
function PriorityList.positions(order)
    local map = {}
    for i = 1, #order do map[order[i]] = i end
    return map
end

--- The indices of `order` whose characters are in `presentSet` (lowercase names).
-- `always` is an index included whatever the set says: the winner of an award is
-- present by construction (it was validated at submit), and must move even if a
-- presence cache disagrees.
function PriorityList.presentIndices(order, presentSet, always)
    local out = {}
    for i = 1, #order do
        if i == always or (presentSet and presentSet[keyOf(order[i])]) then
            out[#out + 1] = i
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- Suicide (section 6)
--------------------------------------------------------------------------------

--- Move the character at index `from` to the last present index, shifting the
-- present characters between them up one. Absent characters keep their index.
-- @param present  sorted array of present indices, `from` among them
function PriorityList.suicideAt(order, from, present)
    local out = {}
    for i = 1, #order do out[i] = order[i] end
    local p
    for k = 1, #present do
        if present[k] == from then p = k end
    end
    if not p then return out end
    for k = p, #present - 1 do
        out[present[k]] = order[present[k + 1]]
    end
    out[present[#present]] = order[from]
    return out
end

--- On winning: the character drops to the bottom of the present characters.
-- @return order', priorIndex, the present indices the move used (for restore and
--         replay), or the same order and nil when the character is not listed
function PriorityList.suicide(order, char, presentSet)
    local from = PriorityList.indexOf(order, char)
    if not from then return order, nil, nil end
    local present = PriorityList.presentIndices(order, presentSet, from)
    return PriorityList.suicideAt(order, from, present), from, present
end

--- Where a suicide would land `char`, and who holds the positions below it.
--
-- The last present index is the bottom of the list as far as a suicide is concerned,
-- and when anyone below it is absent that is not the last row on screen. The panel
-- names both before the click, because "Bottom" that visibly is not the bottom reads
-- as a broken button rather than as the rule in section 6.
--
-- Everything below the landing index is absent by construction: the index is the last
-- present one.
-- @return to, from, array of the absent characters below `to` in list order, or nil
function PriorityList.suicidePreview(order, char, presentSet)
    local from = PriorityList.indexOf(order, char)
    if not from then return nil end
    local present = PriorityList.presentIndices(order, presentSet, from)
    local to = present[#present]
    local held = {}
    for i = to + 1, #order do held[#held + 1] = order[i] end
    return to, from, held
end

--- Undo a suicide: the character returns to `index`, and the present characters that
-- moved up shift back down. `present` is the index array the suicide used, so the
-- restore is an exact inverse whoever has since come or gone.
--
-- When the list has moved since (a later suicide shifted the character, a removal
-- closed a gap) the recorded indices no longer describe it, and this returns nil
-- and a reason rather than a silent no-op: leaving someone suicided for an item they
-- never received is the worst outcome this feature can produce (spec 010 section 6).
-- The caller then restores against the present raid (restoreNow).
-- @return order', or nil plus a reason
function PriorityList.restore(order, char, index, present)
    local at = PriorityList.indexOf(order, char)
    if not at then return nil, tostring(char) .. " is not on the list" end
    if at == index then return order end

    local p, q
    for k = 1, #present do
        if present[k] == index then p = k end
        if present[k] == at then q = k end
    end
    if not p then
        return nil, "position " .. tostring(index) .. " is not among the recorded present indices"
    end
    if not q then
        return nil, tostring(char) .. " is now at " .. at .. ", which the recorded present indices do not cover"
    end
    if p > q then
        return nil, tostring(char) .. " is already above position " .. tostring(index)
    end

    local out = {}
    for i = 1, #order do out[i] = order[i] end
    for k = q, p + 1, -1 do
        out[present[k]] = order[present[k - 1]]
    end
    out[present[p]] = order[at]
    return out
end

--- Restore against the raid as it stands now: the character returns to `index` and
-- the present characters between shift down. The fallback when the recorded indices
-- no longer fit, and the shape of a manual restore (section 10).
-- @return order', present indices used, or nil plus a reason
function PriorityList.restoreNow(order, char, index, presentSet)
    local at = PriorityList.indexOf(order, char)
    if not at then return nil, nil, tostring(char) .. " is not on the list" end
    if index >= at then return nil, nil, tostring(char) .. " is already at or above " .. tostring(index) end
    local present = PriorityList.presentIndices(order, presentSet, at)
    local has = false
    for _, i in ipairs(present) do
        if i == index then has = true end
    end
    if not has then
        present[#present + 1] = index
        table.sort(present)
    end
    local out, why = PriorityList.restore(order, char, index, present)
    if not out then return nil, nil, why end
    return out, present
end

--- Apply a round's suicides once per winning character, in (item index, copy) order
-- (section 7). The present set is the raid at close, the same for every suicide.
-- @param awards  array of { itemIdx, copy, char } in that order
-- @return order', array of { char, from, to, present } in the order applied
function PriorityList.suicideAll(order, awards, presentSet)
    local out = order
    local events, done = {}, {}
    for _, a in ipairs(awards) do
        local key = keyOf(a.char)
        if not done[key] then
            done[key] = true
            local next_, from, present = PriorityList.suicide(out, a.char, presentSet)
            if from then
                out = next_
                events[#events + 1] = { char = a.char, from = from,
                                        to = present[#present], present = present }
            end
        end
    end
    return out, events
end

--------------------------------------------------------------------------------
-- Roster churn
--------------------------------------------------------------------------------

--- A newly claimed character joins at the bottom.
function PriorityList.addChar(order, char)
    if PriorityList.indexOf(order, char) then return order end
    local out = {}
    for i = 1, #order do out[i] = order[i] end
    out[#out + 1] = char
    return out
end

--- A character nobody claims any more leaves and the gap closes.
function PriorityList.removeChar(order, char)
    local at = PriorityList.indexOf(order, char)
    if not at then return order end
    local out = {}
    for i = 1, #order do
        if i ~= at then out[#out + 1] = order[i] end
    end
    return out
end

--- Manual reorder (section 10).
function PriorityList.move(order, from, to)
    local out = {}
    for i = 1, #order do out[i] = order[i] end
    Util.move(out, from, to)
    return out
end

--------------------------------------------------------------------------------
-- Replay (section 8): the stored list, recomputed from the seed and every event
--------------------------------------------------------------------------------

--- Apply one logged event.
-- kinds: seed { seed, chars } · suicide { char, from, present } · restore { char, to,
-- present } · move { from, to } · add { char } · remove { char }
function PriorityList.apply(order, event)
    local kind = event.kind
    if kind == "seed" then
        return PriorityList.seed(event.chars or {}, PriorityList.rngFrom(event.seed))
    elseif kind == "suicide" then
        local from = PriorityList.indexOf(order, event.char)
        if from ~= event.from then return order, "expected " .. tostring(event.char)
            .. " at " .. tostring(event.from) .. ", found " .. tostring(from) end
        return PriorityList.suicideAt(order, from, event.present or { from })
    elseif kind == "restore" then
        local out, why = PriorityList.restore(order, event.char, event.to, event.present or { event.to })
        if not out then return order, why end
        return out
    elseif kind == "move" then
        return PriorityList.move(order, event.from, event.to)
    elseif kind == "add" then
        return PriorityList.addChar(order, event.char)
    elseif kind == "remove" then
        return PriorityList.removeChar(order, event.char)
    end
    return order, "unknown event kind " .. tostring(kind)
end

--- Recompute the list from the seed and the chronological events.
-- @param events  sorted by the version each produced
-- @return order, array of { version, why } for events that did not apply cleanly
function PriorityList.replay(seed, chars, events)
    local order = PriorityList.seed(chars or {}, PriorityList.rngFrom(seed))
    local problems = {}
    for _, event in ipairs(events or {}) do
        local next_, why = PriorityList.apply(order, event)
        if why then problems[#problems + 1] = { version = event.version, why = why } end
        order = next_
    end
    return order, problems
end

--------------------------------------------------------------------------------
-- The viewer (spec 011)
--------------------------------------------------------------------------------

--- Is a list position "near the top" (spec 010 section 11)? The median is taken
-- over the positions of the characters actually in the raid; absent characters do
-- not count towards it, because they are not who you are competing with tonight.
--
-- One definition, used by both the roll window rows and the list viewer. Two
-- copies would drift, and the drift is invisible until two players compare
-- screens on the same night (spec 011 section 4).
function PriorityList.aboveMedian(position, presentPositions)
    if not position or not presentPositions or #presentPositions == 0 then return false end
    local sorted = {}
    for i, v in ipairs(presentPositions) do sorted[i] = v end
    table.sort(sorted)
    local median = sorted[math.ceil(#sorted / 2)]
    return position <= median
end

--- The rows the read-only viewer draws (spec 011 section 4).
--
-- Every WoW-facing lookup is resolved by the caller and passed in, so the whole
-- row model is arithmetic over plain tables and the viewer itself holds no logic.
--
-- @param order array of character names, in list order
-- @param ctx   { owners = { [char] = owner }, present = { [char] = true },
--                classes = { [char] = "WARRIOR" }, contested = { [char] = true },
--                tiers = { [char] = 2 }, me = "Playername" }
--
-- `tiers` is a character's tier in its OWNER's hierarchy, never anything derived
-- from this list: the two are orthogonal (spec 010 section 3). A character whose
-- owner has published nothing carries a nil tier rather than a made-up one.
-- @return array of { position, char, owner, class, isSelf, contested, present,
--         tier, aboveMedian }
function PriorityList.viewRows(order, ctx)
    order = order or {}
    ctx = ctx or {}
    local owners, present = ctx.owners or {}, ctx.present or {}
    local classes, contested = ctx.classes or {}, ctx.contested or {}
    local tiers = ctx.tiers or {}
    local me = keyOf(ctx.me)

    -- The median is over who is here, so it needs a pass of its own first.
    local presentPositions = {}
    for i = 1, #order do
        if present[order[i]] then presentPositions[#presentPositions + 1] = i end
    end

    local rows = {}
    for i = 1, #order do
        local char = order[i]
        local owner = owners[char]
        rows[i] = {
            position = i,
            char = char,
            owner = owner,
            class = classes[char],
            isSelf = me ~= nil and owner ~= nil and keyOf(owner) == me,
            contested = contested[char] == true,
            present = present[char] == true,
            tier = tiers[char],
            aboveMedian = PriorityList.aboveMedian(i, presentPositions),
        }
    end
    return rows
end

--- Positions where two orders disagree.
function PriorityList.diff(a, b)
    local out = {}
    for i = 1, math.max(#a, #b) do
        if keyOf(a[i]) ~= keyOf(b[i]) then
            out[#out + 1] = { index = i, stored = a[i], replayed = b[i] }
        end
    end
    return out
end
